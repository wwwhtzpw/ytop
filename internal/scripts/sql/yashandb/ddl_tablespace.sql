-- File Name: ddl_tablespace.sql
-- Purpose: Generate CREATE TABLESPACE DDL; empty name means all non-system
-- Created: 20260802 by huangtingzhong
--
-- Notes:
--   1) DBMS_METADATA.GET_DDL('TABLESPACE') is not supported on YashanDB 23.5;
--      DDL is reconstructed from DBA_TABLESPACES / DBA_DATA_FILES / DBA_TEMP_FILES.
--   2) Empty tablespace_name => exclude SYSTEM, SYSAUX, UNDO, TEMP, SWAP.
--   3) Explicit name => that tablespace only (including system ones).
--   4) Path rewrite (YashanDB CREATE TABLESPACE): if file is under default
--      $YASDB_DATA/dbfiles/, emit '?/dbfiles/<name>' instead of absolute path.
--      Doc: ? or . can substitute $YASDB_DATA (e.g. '?/dbfiles/yashan').
--      Verified on 23.5.2.101: '?/dbfiles/x', './dbfiles/x', zero-path 'x' all OK;
--      preferred portable form is '?/dbfiles/...'.
--
-- Usage: ytop -f ddl_tablespace.sql
-- Example: tablespace_name=USERS   or leave empty for all non-system

SET SERVEROUTPUT ON

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Generate TABLESPACE DDL (dictionary reconstruct)                       |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT tablespace_name PROMPT 'Enter tablespace_name (empty=all non-system): '

DECLARE
  v_filter VARCHAR2(128) := NULLIF(UPPER(TRIM('&&tablespace_name')), '');
  v_cnt    PLS_INTEGER := 0;

  FUNCTION fmt_size(p_bytes NUMBER) RETURN VARCHAR2 IS
    c_k CONSTANT NUMBER := 1024;
    c_m CONSTANT NUMBER := 1024 * 1024;
    c_g CONSTANT NUMBER := 1024 * 1024 * 1024;
  BEGIN
    IF p_bytes IS NULL OR p_bytes <= 0 THEN
      RETURN '1M';
    ELSIF MOD(p_bytes, c_g) = 0 THEN
      RETURN TO_CHAR(p_bytes / c_g) || 'G';
    ELSIF MOD(p_bytes, c_m) = 0 THEN
      RETURN TO_CHAR(p_bytes / c_m) || 'M';
    ELSIF MOD(p_bytes, c_k) = 0 THEN
      RETURN TO_CHAR(p_bytes / c_k) || 'K';
    ELSE
      RETURN TO_CHAR(p_bytes);
    END IF;
  END;

  FUNCTION is_autoextend_on(p_auto VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN UPPER(NVL(p_auto, 'NO')) IN ('YES', 'ON', 'TRUE', 'Y');
  END;

  -- 将默认数据目录下的绝对路径改写为 ?/$YASDB_DATA 相对路径, 便于跨机复用
  FUNCTION normalize_file_path(p_path VARCHAR2) RETURN VARCHAR2 IS
    v_path   VARCHAR2(4000) := p_path;
    v_pos    PLS_INTEGER;
    v_home   VARCHAR2(4000);
    v_sysf   VARCHAR2(4000);
  BEGIN
    IF v_path IS NULL OR LENGTH(TRIM(v_path)) = 0 THEN
      RETURN v_path;
    END IF;
    -- YFS / 已是相对或 ? 形式, 原样保留
    IF SUBSTR(v_path, 1, 1) IN ('+', '?', '.') THEN
      RETURN v_path;
    END IF;
    IF INSTR(v_path, '/') = 0 AND INSTR(v_path, '\') = 0 THEN
      -- 零路径文件名, 官方落在 $YASDB_DATA/dbfiles
      RETURN v_path;
    END IF;

    -- 标准布局: .../dbfiles/<name> => ?/dbfiles/<name>
    v_pos := INSTR(v_path, '/dbfiles/');
    IF v_pos > 0 THEN
      RETURN '?' || SUBSTR(v_path, v_pos);
    END IF;
    v_pos := INSTR(UPPER(v_path), '\DBFILES\');
    IF v_pos > 0 THEN
      RETURN '?' || REPLACE(SUBSTR(v_path, v_pos), '\', '/');
    END IF;

    -- 非 dbfiles 但位于 $YASDB_DATA 下: 用 SYSTEM 数据文件反推 data home
    BEGIN
      SELECT file_name INTO v_sysf
        FROM dba_data_files
       WHERE tablespace_name = 'SYSTEM'
         AND ROWNUM = 1;
      v_pos := INSTR(v_sysf, '/dbfiles/');
      IF v_pos > 1 THEN
        v_home := SUBSTR(v_sysf, 1, v_pos - 1); -- $YASDB_DATA
        IF v_home IS NOT NULL
           AND SUBSTR(v_path, 1, LENGTH(v_home) + 1) = v_home || '/' THEN
          RETURN '?' || SUBSTR(v_path, LENGTH(v_home) + 1);
        END IF;
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;

    RETURN v_path;
  END;

  PROCEDURE put(p_line VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(p_line);
  END;

  PROCEDURE emit_file_clause(
    p_file_name  VARCHAR2,
    p_bytes      NUMBER,
    p_auto       VARCHAR2,
    p_next_size  NUMBER,
    p_maxbytes   NUMBER,
    p_is_temp    BOOLEAN
  ) IS
    v_clause VARCHAR2(4000);
    v_path   VARCHAR2(4000) := normalize_file_path(p_file_name);
  BEGIN
    IF p_is_temp THEN
      v_clause := '  TEMPFILE ''' || v_path || ''' SIZE ' || fmt_size(p_bytes);
    ELSE
      v_clause := '  DATAFILE ''' || v_path || ''' SIZE ' || fmt_size(p_bytes);
    END IF;
    IF is_autoextend_on(p_auto) THEN
      v_clause := v_clause || ' AUTOEXTEND ON NEXT ' || fmt_size(NVL(p_next_size, p_bytes));
      -- YashanDB: MAXSIZE UNLIMITED 仅在字典未给出有效 maxbytes 时使用.
      -- 产品上限(8K 块): 非 UNDO 单文件最多 64MB 块 = 512G; UNDO 最多 8MB 块 = 64G.
      -- 字典常见值即为 512G/64G, 应原样输出, 勿改写成 UNLIMITED.
      IF p_maxbytes IS NULL OR p_maxbytes <= 0 THEN
        v_clause := v_clause || ' MAXSIZE UNLIMITED';
      ELSE
        v_clause := v_clause || ' MAXSIZE ' || fmt_size(p_maxbytes);
      END IF;
    ELSE
      v_clause := v_clause || ' AUTOEXTEND OFF';
    END IF;
    put(v_clause);
  END;

  PROCEDURE emit_tablespace(p_ts_name VARCHAR2) IS
    v_contents   VARCHAR2(30);
    v_blksize    NUMBER;
    v_is_temp    BOOLEAN;
    v_create_kw  VARCHAR2(80);
    v_file_kw    VARCHAR2(20);
    v_first      BOOLEAN := TRUE;
    v_file_cnt   PLS_INTEGER := 0;
  BEGIN
    SELECT contents, block_size
      INTO v_contents, v_blksize
      FROM dba_tablespaces
     WHERE tablespace_name = p_ts_name;

    v_is_temp := UPPER(v_contents) IN ('TEMPORARY', 'SWAP');

    IF UPPER(v_contents) = 'TEMPORARY' THEN
      v_create_kw := 'CREATE TEMPORARY TABLESPACE ' || p_ts_name;
      v_file_kw := 'TEMPFILE';
    ELSIF UPPER(v_contents) = 'UNDO' THEN
      -- YashanDB 23.5: CREATE UNDO TABLESPACE may be unsupported; emit DATAFILE form
      v_create_kw := 'CREATE TABLESPACE ' || p_ts_name;
      v_file_kw := 'DATAFILE';
      v_is_temp := FALSE;
    ELSIF UPPER(v_contents) = 'SWAP' THEN
      v_create_kw := 'CREATE TEMPORARY TABLESPACE ' || p_ts_name;
      v_file_kw := 'TEMPFILE';
    ELSE
      v_create_kw := 'CREATE TABLESPACE ' || p_ts_name;
      v_file_kw := 'DATAFILE';
    END IF;

    IF v_is_temp THEN
      FOR f IN (
        SELECT file_name,
               bytes,
               autoextensible,
               increment_by * NVL(v_blksize, 8192) AS next_bytes,
               maxbytes
          FROM dba_temp_files
         WHERE tablespace_name = p_ts_name
         ORDER BY file_id
      ) LOOP
        v_file_cnt := v_file_cnt + 1;
        IF v_first THEN
          put(v_create_kw);
          emit_file_clause(f.file_name, f.bytes, f.autoextensible, f.next_bytes, f.maxbytes, TRUE);
          put(';');
          v_first := FALSE;
        ELSE
          put('ALTER TABLESPACE ' || p_ts_name || ' ADD ' || v_file_kw);
          emit_file_clause(f.file_name, f.bytes, f.autoextensible, f.next_bytes, f.maxbytes, TRUE);
          put(';');
        END IF;
      END LOOP;
      -- fallback: some builds expose TEMP/SWAP only in dba_data_files
      IF v_file_cnt = 0 THEN
        FOR f IN (
          SELECT file_name, bytes, autoextensible, next_size, maxbytes
            FROM dba_data_files
           WHERE tablespace_name = p_ts_name
           ORDER BY file_id
        ) LOOP
          v_file_cnt := v_file_cnt + 1;
          IF v_first THEN
            put(v_create_kw);
            emit_file_clause(f.file_name, f.bytes, f.autoextensible, f.next_size, f.maxbytes, TRUE);
            put(';');
            v_first := FALSE;
          ELSE
            put('ALTER TABLESPACE ' || p_ts_name || ' ADD TEMPFILE');
            emit_file_clause(f.file_name, f.bytes, f.autoextensible, f.next_size, f.maxbytes, TRUE);
            put(';');
          END IF;
        END LOOP;
      END IF;
    ELSE
      FOR f IN (
        SELECT file_name, bytes, autoextensible, next_size, maxbytes
          FROM dba_data_files
         WHERE tablespace_name = p_ts_name
         ORDER BY file_id
      ) LOOP
        v_file_cnt := v_file_cnt + 1;
        IF v_first THEN
          put(v_create_kw);
          emit_file_clause(f.file_name, f.bytes, f.autoextensible, f.next_size, f.maxbytes, FALSE);
          put(';');
          v_first := FALSE;
        ELSE
          put('ALTER TABLESPACE ' || p_ts_name || ' ADD DATAFILE');
          emit_file_clause(f.file_name, f.bytes, f.autoextensible, f.next_size, f.maxbytes, FALSE);
          put(';');
        END IF;
      END LOOP;
    END IF;

    IF v_file_cnt = 0 THEN
      put('-- WARN: no datafile/tempfile found for ' || p_ts_name);
    END IF;
    put('');
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      put('-- ERROR: tablespace not found: ' || p_ts_name);
      put('');
  END;

BEGIN
  put('-- Generated by ddl_tablespace.sql');
  put('-- filter=' || NVL(v_filter, '<all non-system>'));
  put('');

  IF v_filter IS NOT NULL THEN
    emit_tablespace(v_filter);
    v_cnt := 1;
  ELSE
    FOR r IN (
      SELECT tablespace_name
        FROM dba_tablespaces
       WHERE tablespace_name NOT IN ('SYSTEM', 'SYSAUX', 'UNDO', 'TEMP', 'SWAP')
         AND UPPER(contents) NOT IN ('UNDO', 'TEMPORARY', 'SWAP')
       ORDER BY tablespace_name
    ) LOOP
      emit_tablespace(r.tablespace_name);
      v_cnt := v_cnt + 1;
    END LOOP;
  END IF;

  IF v_cnt = 0 THEN
    put('-- no matching tablespace');
  END IF;
END;
/
