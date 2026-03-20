-- File Name: yashan_redo_recreate.sql
-- Purpose: Add/drop redo log files by size and path, switch by ARCHIVE LOG CURRENT (single-node or cluster).
-- Created: 20260309  by  huangtingzhong
-- Params: p_redo_count (default 6 per instance), p_redo_size (default 4G), p_redo_path (default empty, from V$LOGFILE)

SET SERVEROUTPUT ON;

DECLARE
  -- ========== 修改此处三行即可传参（组数/大小/路径）==========
  p_redo_count  PLS_INTEGER   := nvl(&redocount,6);                    -- 每实例 redo 组数，默认 6
  p_redo_size   VARCHAR2(32)  := nvl('&size','4G');                 -- redo 大小，默认 4G
  p_redo_path   VARCHAR2(512) := nvl('&path','');           -- 目标路径，空=从 V$LOGFILE 取
  p_max_switch  PLS_INTEGER   := 20;                  -- 单条 redo 删除前最多切换次数
  -- ========================================================

  v_default_path   VARCHAR2(512);
  v_target_path    VARCHAR2(512);
  v_target_bytes   NUMBER;
  v_redo_name      VARCHAR2(512);
  v_status        VARCHAR2(32);
  v_switch_cnt    PLS_INTEGER;
  v_sql           VARCHAR2(1024);
  v_size_str      VARCHAR2(32);
  v_i             PLS_INTEGER;
  v_redo_count    PLS_INTEGER;   -- 当前 redo 总数，删除前需保证删除后仍 >= 3
  c_min_redo      CONSTANT PLS_INTEGER := 3;  -- YashanDB 要求在线 redo 至少 3 个
  v_start_ts      DATE;          -- SQL 执行开始时间（用 DATE 便于算毫秒差）
  v_elapsed_ms    NUMBER;        -- SQL 执行耗时（毫秒）
  v_exists        PLS_INTEGER;   -- V$LOGFILE 中是否已存在同名文件（1=存在）
  v_retry         PLS_INTEGER;   -- 名称冲突时重试后缀
  c_max_retry     CONSTANT PLS_INTEGER := 99;  -- 单文件最多重试次数
  v_match_count   PLS_INTEGER;   -- 当前已满足路径+大小的 redo 数量
  v_inst_id       PLS_INTEGER;   -- 当前活动实例号（删除 redo 时只删本实例）

  -- 将 p_redo_size（如 200M/1G）转换为字节数
  FUNCTION size_to_bytes(p_size VARCHAR2) RETURN NUMBER IS
    v_s VARCHAR2(32);
    v_n NUMBER;
  BEGIN
    v_s := TRIM(UPPER(p_size));
    IF REGEXP_LIKE(v_s, '^[0-9]+M$') THEN
      v_n := TO_NUMBER(REGEXP_SUBSTR(v_s, '^[0-9]+'));
      RETURN v_n * 1024 * 1024;
    ELSIF REGEXP_LIKE(v_s, '^[0-9]+G$') THEN
      v_n := TO_NUMBER(REGEXP_SUBSTR(v_s, '^[0-9]+'));
      RETURN v_n * 1024 * 1024 * 1024;
    ELSIF REGEXP_LIKE(v_s, '^[0-9]+$') THEN
      RETURN TO_NUMBER(v_s);
    ELSE
      RAISE_APPLICATION_ERROR(-20001, 'Invalid redo size format: ' || p_size || ', use 200M, 1G or bytes');
    END IF;
  END size_to_bytes;

BEGIN
  -- 1) 解析目标大小（字节）
  v_target_bytes := size_to_bytes(p_redo_size);
  v_size_str     := p_redo_size;

  -- 2) 确定目标路径：若未指定则从 V$LOGFILE 取第一条 NAME 的目录
  IF p_redo_path IS NULL OR TRIM(p_redo_path) = '' THEN
    SELECT SUBSTR(TRIM(NAME), 1,
                  LENGTH(TRIM(NAME)) - LENGTH(SUBSTRING_INDEX(TRIM(NAME), '/', -1)) - 1)
      INTO v_default_path
      FROM (SELECT NAME FROM V$LOGFILE WHERE ROWNUM = 1);
    v_target_path := RTRIM(v_default_path);
    DBMS_OUTPUT.PUT_LINE('Using default redo path: ' || v_target_path);
  ELSE
    v_target_path := RTRIM(TRIM(p_redo_path));
    IF SUBSTR(v_target_path, -1) = '/' THEN
      v_target_path := RTRIM(SUBSTR(v_target_path, 1, LENGTH(v_target_path) - 1));
    END IF;
    -- YAC 磁盘组：路径以 + 开头（如 +DATA）时，自动在磁盘组下使用 dbfiles 目录
    IF SUBSTR(v_target_path, 1, 1) = '+' THEN
      v_target_path := v_target_path || '/dbfiles';
      DBMS_OUTPUT.PUT_LINE('YAC disk group detected, redo path: ' || v_target_path);
    END IF;
  END IF;

  DBMS_OUTPUT.PUT_LINE('Target path=' || v_target_path || ', size=' || v_size_str || ' (' || v_target_bytes || ' bytes), required ' || p_redo_count || ' file(s) per instance (YAC cluster: count is per instance, not whole DB).');

  -- 判断当前是否已满足：指定路径下、指定大小的 redo 数量 >= p_redo_count 则无需添加
  SELECT COUNT(*) INTO v_match_count
    FROM V$LOGFILE l
   WHERE SUBSTR(TRIM(l.NAME), 1, LENGTH(TRIM(l.NAME)) - LENGTH(SUBSTRING_INDEX(TRIM(l.NAME), '/', -1)) - 1) = v_target_path
     AND (l.BLOCK_SIZE * l.BLOCK_COUNT) = v_target_bytes;
  IF v_match_count >= p_redo_count THEN
    DBMS_OUTPUT.PUT_LINE('Already satisfied: ' || v_match_count || ' redo file(s) match path and size (required >= ' || p_redo_count || '), skip adding.');
  ELSE
  -- 3) 添加新 redo 文件（先查 V$LOGFILE 是否已存在同名，存在则重新生成名称再查直到不存在）
  FOR v_i IN 1 .. (p_redo_count - v_match_count) LOOP
    v_retry := 0;
    LOOP
      IF v_retry = 0 THEN
        v_redo_name := v_target_path || '/redo_' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS') || '_' || v_i || '.log';
      ELSE
        v_redo_name := v_target_path || '/redo_' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS') || '_' || v_i || '_' || v_retry || '.log';
      END IF;
      SELECT COUNT(*) INTO v_exists FROM V$LOGFILE WHERE TRIM(NAME) = v_redo_name;
      EXIT WHEN v_exists = 0;
      v_retry := v_retry + 1;
      IF v_retry > c_max_retry THEN
        RAISE_APPLICATION_ERROR(-20002, 'Cannot get unique redo name for ' || v_i || ' after ' || c_max_retry || ' retries');
      END IF;
    END LOOP;
    v_sql       := 'ALTER DATABASE ADD LOGFILE ''' || REPLACE(v_redo_name, '''', '''''') || ''' SIZE ' || v_size_str;
    v_start_ts  := SYSDATE;
    EXECUTE IMMEDIATE v_sql;
    v_elapsed_ms := ROUND((SYSDATE - v_start_ts) * 86400 * 1000);
    DBMS_OUTPUT.PUT_LINE('[SQL] ' || v_sql || '  -- ' || v_elapsed_ms || ' ms');
  END LOOP;
  END IF;

  -- 4) 删除所有实例中路径或大小与目标不一致的 redo（单节点管理全集群，其它实例需为 OPEN）
  SELECT instance_number INTO v_inst_id FROM V$INSTANCE WHERE status = 'OPEN' AND ROWNUM = 1;
  DBMS_OUTPUT.PUT_LINE('Current instance (OPEN): ' || v_inst_id || ', drop redo for all instances (other instances must be OPEN).');

  FOR rec IN (
    SELECT l.THREAD# AS thread_id,
           TRIM(l.NAME) AS log_name,
           l.BLOCK_SIZE * l.BLOCK_COUNT AS file_bytes,
           l.STATUS AS log_status
      FROM GV$LOGFILE l
     WHERE ( SUBSTR(TRIM(l.NAME), 1, LENGTH(TRIM(l.NAME)) - LENGTH(SUBSTRING_INDEX(TRIM(l.NAME), '/', -1)) - 1) <> v_target_path
             OR (l.BLOCK_SIZE * l.BLOCK_COUNT) <> v_target_bytes
           )
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('Process redo [THREAD#=' || rec.thread_id || ']: ' || rec.log_name || ' (status=' || rec.log_status || ')');

    -- 单机/集群统一用 ARCHIVE LOG CURRENT 切换（集群下会切换整个集群）
    v_status     := rec.log_status;
    v_switch_cnt := 0;
    WHILE v_status IN ('CURRENT', 'ACTIVE') AND v_switch_cnt < p_max_switch LOOP
      v_switch_cnt := v_switch_cnt + 1;
      DBMS_OUTPUT.PUT_LINE('  Archive log current round ' || v_switch_cnt || '/' || p_max_switch);
      EXECUTE IMMEDIATE 'ALTER SYSTEM ARCHIVE LOG CURRENT';
      BEGIN
        SELECT TRIM(g.STATUS) INTO v_status FROM GV$LOGFILE g WHERE g.THREAD# = rec.thread_id AND TRIM(g.NAME) = rec.log_name;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          v_status := 'INACTIVE';
      END;
    END LOOP;

    IF v_status IN ('INACTIVE', 'NEW') THEN
      SELECT COUNT(*) INTO v_redo_count FROM GV$LOGFILE WHERE THREAD# = rec.thread_id;
      IF v_redo_count <= c_min_redo THEN
        DBMS_OUTPUT.PUT_LINE('  SKIP drop ' || rec.log_name || ': instance ' || rec.thread_id || ' only has ' || v_redo_count || ' redo (min ' || c_min_redo || ')');
      ELSE
        IF rec.thread_id = v_inst_id THEN
          v_sql := 'ALTER DATABASE DROP LOGFILE ''' || REPLACE(rec.log_name, '''', '''''') || '''';
        ELSE
          v_sql := 'ALTER DATABASE DROP LOGFILE THREAD ' || rec.thread_id || ' ''' || REPLACE(rec.log_name, '''', '''''') || '''';
        END IF;
        v_start_ts := SYSDATE;
        EXECUTE IMMEDIATE v_sql;
        v_elapsed_ms := ROUND((SYSDATE - v_start_ts) * 86400 * 1000);
        DBMS_OUTPUT.PUT_LINE('[SQL] ' || v_sql || '  -- ' || v_elapsed_ms || ' ms');
      END IF;
    ELSE
      DBMS_OUTPUT.PUT_LINE('  WARN: skip drop ' || rec.log_name || ' (status=' || v_status || '), need manual switch later');
    END IF;
  END LOOP;

  -- 5) 输出当前全部 redo 信息（含 THREAD#）
  DBMS_OUTPUT.PUT_LINE('--- Current redo (V$LOGFILE) ---');
  DBMS_OUTPUT.PUT_LINE(RPAD('ID', 6) || ' ' || RPAD('THREAD#', 8) || ' ' || RPAD('NAME', 68) || ' ' || RPAD('SIZE_MB', 10) || ' ' || 'STATUS');
  DBMS_OUTPUT.PUT_LINE(LPAD('-', 6, '-') || ' ' || LPAD('-', 8, '-') || ' ' || LPAD('-', 68, '-') || ' ' || LPAD('-', 10, '-') || ' ' || '------');
  FOR r IN (SELECT l.ID, l.THREAD#, TRIM(l.NAME) AS log_name, ROUND((l.BLOCK_SIZE * l.BLOCK_COUNT) / 1024 / 1024) AS size_mb, l.STATUS FROM V$LOGFILE l ORDER BY l.THREAD#, l.ID) LOOP
    DBMS_OUTPUT.PUT_LINE(LPAD(r.ID, 6) || ' ' || LPAD(NVL(TO_CHAR(r.THREAD#), '-'), 8) || ' ' || RPAD(SUBSTR(r.log_name, 1, 68), 68) || ' ' || LPAD(r.size_mb, 10) || ' ' || r.STATUS);
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('--- End of V$LOGFILE ---');

  DBMS_OUTPUT.PUT_LINE('Done.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
    RAISE;
END;
/
