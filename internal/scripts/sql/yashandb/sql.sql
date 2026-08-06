-- File Name: sql.sql
-- Purpose: YashanDB SQL tuning report (ORIGINAL+LITERAL SQL, plan, objects)
-- Created: 20251201  by  huangtingzhong
-- Updated: 20260805 by huangtingzhong (fast bind pick: last_captured filter + PL/SQL position dedupe)

set heading on;
set serveroutput on;
prompt
prompt ****************************************************************************************
prompt ORIGINAL SQL / LITERAL SQL
prompt ****************************************************************************************

DECLARE
  c_sqlid           CONSTANT VARCHAR2(64) := '&&sqlid';
  -- UTF8: SUBSTR into VARCHAR2(4000) may exceed byte limit; keep emit chunk small
  c_chunk           CONSTANT PLS_INTEGER := 1000;
  c_varchar_limit   CONSTANT PLS_INTEGER := 32000;

  lvc_sql_text      VARCHAR2(32000);
  lvc_orig_sql_text CLOB;
  ln_child          NUMBER := 10000;
  ln_exec_child     NUMBER;
  ln_hash           NUMBER;
  ln_phv            NUMBER;
  ln_sql_len        NUMBER;
  lvc_repl          VARCHAR2(8000);
  lvc_bind          VARCHAR2(200);
  lvc_name          VARCHAR2(64);
  lvc_sql_tmp       VARCHAR2(32767);

  ln_bind_count     NUMBER := 0;
  ln_sql_cnt        NUMBER := 0;
  ln_qpos           NUMBER;

  -- 已处理的 bind position (同 child 多 ADDRESS 时去重)
  TYPE t_pos_seen IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
  v_pos_seen        t_pos_seen;

  -- 轻量游标: 只过滤 last_captured; 多 ADDRESS 在循环里按 position 去重
  CURSOR c1(p_child NUMBER) IS
    SELECT child_number,
           name,
           position,
           datatype_string,
           value_string,
           sql_id
      FROM v$sql_bind_capture
     WHERE sql_id = c_sqlid
       AND child_number = p_child
       AND last_captured IS NOT NULL
     ORDER BY last_captured DESC NULLS LAST,
              CASE WHEN name IS NOT NULL AND TRIM(name) <> '?' THEN 0 ELSE 1 END,
              position;

  PROCEDURE put_clob(p_text IN CLOB) IS
    v_len NUMBER;
    v_off NUMBER := 1;
    v_buf VARCHAR2(4000);
  BEGIN
    IF p_text IS NULL THEN
      RETURN;
    END IF;
    v_len := NVL(DBMS_LOB.GETLENGTH(p_text), 0);
    IF v_len = 0 THEN
      RETURN;
    END IF;
    WHILE v_off <= v_len LOOP
      v_buf := DBMS_LOB.SUBSTR(p_text, LEAST(c_chunk, v_len - v_off + 1), v_off);
      DBMS_OUTPUT.PUT_LINE(v_buf);
      v_off := v_off + c_chunk;
    END LOOP;
  END;

  PROCEDURE put_varchar(p_text IN VARCHAR2) IS
    v_len PLS_INTEGER;
    v_off PLS_INTEGER := 1;
  BEGIN
    IF p_text IS NULL THEN
      RETURN;
    END IF;
    v_len := NVL(LENGTH(p_text), 0);
    WHILE v_off <= v_len LOOP
      DBMS_OUTPUT.PUT_LINE(SUBSTR(p_text, v_off, c_chunk));
      v_off := v_off + c_chunk;
    END LOOP;
  END;

  FUNCTION replace_first_outside_quotes(
    p_text        IN VARCHAR2,
    p_pattern     IN VARCHAR2,
    p_replacement IN VARCHAR2
  ) RETURN VARCHAR2 IS
    v_pos      PLS_INTEGER := 1;
    v_len      PLS_INTEGER := NVL(LENGTH(p_text), 0);
    v_plen     PLS_INTEGER := NVL(LENGTH(p_pattern), 0);
    v_in_quote BOOLEAN := FALSE;
    v_result   VARCHAR2(32767) := '';
    v_ch       CHAR(1);
    v_next     CHAR(1);
  BEGIN
    IF v_len = 0 OR v_plen = 0 THEN
      RETURN p_text;
    END IF;

    WHILE v_pos <= v_len LOOP
      v_ch := SUBSTR(p_text, v_pos, 1);

      IF v_ch = '''' THEN
        IF v_in_quote
           AND v_pos < v_len
           AND SUBSTR(p_text, v_pos + 1, 1) = '''' THEN
          v_result := v_result || '''''';
          v_pos := v_pos + 2;
        ELSE
          v_in_quote := NOT v_in_quote;
          v_result := v_result || v_ch;
          v_pos := v_pos + 1;
        END IF;
      ELSIF NOT v_in_quote
            AND v_pos + v_plen - 1 <= v_len
            AND UPPER(SUBSTR(p_text, v_pos, v_plen)) = UPPER(p_pattern) THEN
        v_next := CASE
                    WHEN v_pos + v_plen <= v_len THEN SUBSTR(p_text, v_pos + v_plen, 1)
                    ELSE NULL
                  END;
        IF p_pattern LIKE ':%'
           AND v_next IS NOT NULL
           AND v_next BETWEEN '0' AND '9' THEN
          v_result := v_result || v_ch;
          v_pos := v_pos + 1;
        ELSE
          RETURN v_result || p_replacement || SUBSTR(p_text, v_pos + v_plen);
        END IF;
      ELSE
        v_result := v_result || v_ch;
        v_pos := v_pos + 1;
      END IF;
    END LOOP;

    RETURN v_result;
  END replace_first_outside_quotes;

  FUNCTION bind_pattern(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    v_bare VARCHAR2(128);
  BEGIN
    IF p_name IS NULL OR LENGTH(TRIM(p_name)) = 0 OR TRIM(p_name) = '?' THEN
      RETURN NULL;
    END IF;
    -- SYS_B: SQL text usually :SYS_B_0 (unquoted); some tools use :"SYS_B_0"
    IF UPPER(LTRIM(p_name, ':')) LIKE 'SYS_B_%'
       OR UPPER(REPLACE(LTRIM(p_name, ':'), '"', '')) LIKE 'SYS_B_%' THEN
      v_bare := REPLACE(LTRIM(p_name, ':'), '"', '');
      RETURN ':' || v_bare;
    ELSIF p_name LIKE ':%' THEN
      RETURN p_name;
    ELSE
      RETURN ':' || LTRIM(p_name, ':');
    END IF;
  END bind_pattern;

  FUNCTION bind_pattern_alt(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    v_bare VARCHAR2(128);
  BEGIN
    IF p_name IS NULL OR LENGTH(TRIM(p_name)) = 0 OR TRIM(p_name) = '?' THEN
      RETURN NULL;
    END IF;
    IF UPPER(REPLACE(LTRIM(p_name, ':'), '"', '')) LIKE 'SYS_B_%' THEN
      v_bare := REPLACE(LTRIM(p_name, ':'), '"', '');
      RETURN ':"' || v_bare || '"';
    END IF;
    RETURN NULL;
  END bind_pattern_alt;

  FUNCTION uses_question_bind(p_text IN VARCHAR2) RETURN BOOLEAN IS
    v_pos      PLS_INTEGER := 1;
    v_len      PLS_INTEGER := NVL(LENGTH(p_text), 0);
    v_in_quote BOOLEAN := FALSE;
    v_ch       CHAR(1);
  BEGIN
    WHILE v_pos <= v_len LOOP
      v_ch := SUBSTR(p_text, v_pos, 1);
      IF v_ch = '''' THEN
        IF v_in_quote
           AND v_pos < v_len
           AND SUBSTR(p_text, v_pos + 1, 1) = '''' THEN
          v_pos := v_pos + 2;
        ELSE
          v_in_quote := NOT v_in_quote;
          v_pos := v_pos + 1;
        END IF;
      ELSIF NOT v_in_quote AND v_ch = '?' THEN
        RETURN TRUE;
      ELSE
        v_pos := v_pos + 1;
      END IF;
    END LOOP;
    RETURN FALSE;
  END uses_question_bind;

BEGIN
  SELECT COUNT(*)
    INTO ln_sql_cnt
    FROM v$sql
   WHERE sql_id = c_sqlid;

  IF ln_sql_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No SQL found in V$SQL for sql_id=' || c_sqlid);
    RETURN;
  END IF;

  -- 选 child: 有 last_captured 的最新一条所在 child (单次轻量扫描, 无相关子查询)
  BEGIN
    SELECT child_number
      INTO ln_exec_child
      FROM (
             SELECT child_number
               FROM v$sql_bind_capture
              WHERE sql_id = c_sqlid
                AND last_captured IS NOT NULL
              ORDER BY last_captured DESC NULLS LAST, child_number
           )
     WHERE ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      ln_exec_child := NULL;
  END;

  IF ln_exec_child IS NOT NULL THEN
    BEGIN
      SELECT sql_fulltext,
             parsing_schema_name,
             child_number,
             hash_value,
             plan_hash_value,
             NVL(DBMS_LOB.GETLENGTH(sql_fulltext), 0)
        INTO lvc_orig_sql_text,
             lvc_name,
             ln_exec_child,
             ln_hash,
             ln_phv,
             ln_sql_len
        FROM v$sql
       WHERE sql_id = c_sqlid
         AND child_number = ln_exec_child
         AND ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        ln_exec_child := NULL;
    END;
  END IF;

  IF ln_exec_child IS NULL THEN
    SELECT sql_fulltext,
           parsing_schema_name,
           child_number,
           hash_value,
           plan_hash_value,
           NVL(DBMS_LOB.GETLENGTH(sql_fulltext), 0)
      INTO lvc_orig_sql_text,
           lvc_name,
           ln_exec_child,
           ln_hash,
           ln_phv,
           ln_sql_len
      FROM (
             SELECT s.sql_fulltext,
                    s.parsing_schema_name,
                    s.child_number,
                    s.hash_value,
                    s.plan_hash_value
               FROM v$sql s
              WHERE s.sql_id = c_sqlid
              ORDER BY s.last_active_time DESC NULLS LAST,
                       s.executions DESC NULLS LAST,
                       s.child_number
           )
     WHERE ROWNUM = 1;
  END IF;

  DBMS_OUTPUT.PUT_LINE('===== ORIGINAL SQL =====');
  DBMS_OUTPUT.PUT_LINE(
    'source=v$sql.sql_fulltext (executed cursor) sql_id=' || c_sqlid
    || ' child=' || TO_CHAR(ln_exec_child)
    || ' schema=' || lvc_name
    || ' hash=' || TO_CHAR(ln_hash)
    || ' phv=' || TO_CHAR(ln_phv)
    || ' chars=' || TO_CHAR(ln_sql_len)
  );
  put_clob(lvc_orig_sql_text);
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');

  SELECT COUNT(*)
    INTO ln_bind_count
    FROM v$sql_bind_capture
   WHERE sql_id = c_sqlid
     AND child_number = ln_exec_child
     AND last_captured IS NOT NULL
     AND ROWNUM = 1;

  IF ln_bind_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE('===== LITERAL SQL =====');
    DBMS_OUTPUT.PUT_LINE(
      'Schema: ' || lvc_name || ' child=' || TO_CHAR(ln_exec_child)
      || ' (no bind capture on executed child; same as ORIGINAL SQL)'
    );
    put_clob(lvc_orig_sql_text);
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
    RETURN;
  END IF;

  IF ln_sql_len > c_varchar_limit THEN
    DBMS_OUTPUT.PUT_LINE('===== LITERAL SQL =====');
    DBMS_OUTPUT.PUT_LINE(
      'WARN: SQL chars=' || TO_CHAR(ln_sql_len)
      || ' > ' || TO_CHAR(c_varchar_limit)
      || '; bind literal rewrite skipped (see ORIGINAL SQL)'
    );
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
    RETURN;
  END IF;

  -- short SQL: bind rewrite on VARCHAR2 copy of executed text
  lvc_sql_text := DBMS_LOB.SUBSTR(lvc_orig_sql_text, ln_sql_len, 1);
  v_pos_seen.DELETE;

  FOR r1 IN c1(ln_exec_child) LOOP
    -- 同 position 多 ADDRESS: 已按 last_captured DESC 排序, 只处理第一次
    IF NOT v_pos_seen.EXISTS(r1.position) THEN
    v_pos_seen(r1.position) := 1;

    IF (r1.child_number <> ln_child) THEN
      IF ln_child <> 10000 THEN
        DBMS_OUTPUT.PUT_LINE('===== LITERAL SQL =====');
        DBMS_OUTPUT.PUT_LINE('Schema: ' || lvc_name || ' child=' || TO_CHAR(ln_child));
        put_varchar(lvc_sql_text);
        DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
      END IF;

      ln_child     := r1.child_number;
      lvc_sql_text := DBMS_LOB.SUBSTR(lvc_orig_sql_text, ln_sql_len, 1);
    END IF;

    BEGIN
      SELECT parsing_schema_name
        INTO lvc_name
        FROM v$sql
       WHERE sql_id = r1.sql_id
         AND child_number = r1.child_number
         AND ROWNUM = 1;
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;

    IF r1.value_string IS NULL THEN
      lvc_repl := 'NULL';
    ELSIF r1.datatype_string = 'NUMBER' THEN
      IF LENGTH(r1.value_string) > 7900 THEN
        lvc_repl := SUBSTR(r1.value_string, 1, 7900);
      ELSE
        lvc_repl := r1.value_string;
      END IF;
    ELSIF r1.datatype_string = 'DATE' THEN
      lvc_repl := 'to_date(''' || REPLACE(SUBSTR(NVL(r1.value_string, ''), 1, 7800), '''', '''''') || ''')';
    ELSIF r1.datatype_string LIKE 'TIMESTAMP%' THEN
      lvc_repl := 'to_timestamp(''' || REPLACE(SUBSTR(NVL(r1.value_string, ''), 1, 7800), '''', '''''') || ''')';
    ELSE
      -- avoid YAS-04412 when value_string exceeds old VARCHAR2(2000) repl buffer
      lvc_repl := '''' || REPLACE(SUBSTR(NVL(r1.value_string, ''), 1, 7800), '''', '''''') || '''';
      IF LENGTH(NVL(r1.value_string, '')) > 7800 THEN
        lvc_repl := lvc_repl || ' /*truncated*/';
      END IF;
    END IF;

    lvc_bind := bind_pattern(r1.name);

    -- 命名占位优先; 失败再回退第一个 ?
    IF lvc_bind IS NOT NULL THEN
      lvc_sql_tmp := replace_first_outside_quotes(lvc_sql_text, lvc_bind, lvc_repl);
      IF lvc_sql_tmp = lvc_sql_text AND bind_pattern_alt(r1.name) IS NOT NULL THEN
        lvc_sql_tmp := replace_first_outside_quotes(
          lvc_sql_text, bind_pattern_alt(r1.name), lvc_repl);
      END IF;
      IF lvc_sql_tmp <> lvc_sql_text THEN
        lvc_sql_text := lvc_sql_tmp;
      ELSE
        ln_qpos := INSTR(lvc_sql_text, '?');
        IF ln_qpos = 0 THEN
          DBMS_OUTPUT.PUT_LINE(
            'ERROR: no placeholder for bind position=' || r1.position
            || ', name=' || NVL(r1.name, '(null)')
          );
          RETURN;
        END IF;
        lvc_sql_text :=
          SUBSTR(lvc_sql_text, 1, ln_qpos - 1) ||
          lvc_repl ||
          SUBSTR(lvc_sql_text, ln_qpos + 1);
      END IF;
    ELSE
      ln_qpos := INSTR(lvc_sql_text, '?');
      IF ln_qpos = 0 THEN
        DBMS_OUTPUT.PUT_LINE(
          'ERROR: no remaining ''?'' placeholders while replacing binds. ' ||
          'bind position=' || r1.position || ', name=' || NVL(r1.name, '(null)')
        );
        RETURN;
      END IF;

      lvc_sql_text :=
        SUBSTR(lvc_sql_text, 1, ln_qpos - 1) ||
        lvc_repl ||
        SUBSTR(lvc_sql_text, ln_qpos + 1);
    END IF;
    END IF; -- position dedupe
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('===== LITERAL SQL =====');
  DBMS_OUTPUT.PUT_LINE(
    'Schema: ' || lvc_name || ' child=' || TO_CHAR(ln_exec_child)
    || ' (bind values from capture; not byte-identical to execute)'
  );
  put_varchar(lvc_sql_text);
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
END;
/



prompt ****************************************************************************************
prompt PLAN from v$sql_plan
prompt ****************************************************************************************

-- Pure SQL plan (no DBMS_OUTPUT); works on READ_ONLY standby.
-- Do not set "col plan_line for aN": yasql pads every row to N chars.

-- One row per (plan_hash_value, id): collapse multi-child / multi-address
-- copies in v$sql_plan so each PHV prints a single plan tree.
WITH ranked AS (
  SELECT p.plan_hash_value AS phv,
         p.id,
         p.parent_id,
         p.depth,
         p.operation,
         p.options,
         p.object_owner,
         p.object_name,
         p.object_type,
         p.object_alias,
         p.cost,
         p.cardinality,
         p.bytes,
         p.time AS plan_time,
         p.cpu_cost,
         p.io_cost,
         p.search_columns,
         p.access_predicates,
         p.filter_predicates,
         p.projection,
         p.partition_info,
         p.partition_start,
         p.partition_stop,
         p.other_tag,
         p.temp_space,
         LPAD(' ', NVL(p.depth, 0) * 2) || p.operation || NVL(' ' || p.options, '') AS op_txt,
         CASE
           WHEN p.object_name IS NOT NULL THEN
             p.object_owner || '.' || p.object_name ||
             CASE
               WHEN p.object_type IS NOT NULL THEN ' [' || p.object_type || ']'
               ELSE ''
             END ||
             CASE
               WHEN LENGTH(TRIM(NVL(p.object_alias, ''))) > 0
               THEN ' (' || TRIM(p.object_alias) || ')'
               ELSE ''
             END
           WHEN LENGTH(TRIM(NVL(p.object_alias, ''))) > 0 THEN
             TRIM(p.object_alias)
           ELSE NULL
         END AS name_txt,
         CASE
           WHEN LENGTH(TRIM(NVL(p.access_predicates, ''))) > 0
           THEN '  -> Access: ' || p.access_predicates
         END AS access_txt,
         CASE
           WHEN LENGTH(TRIM(NVL(p.filter_predicates, ''))) > 0
           THEN '  -> Filter: ' || p.filter_predicates
         END AS filter_txt,
         -- Prefer PARTITION_INFO; append PARTITION_START..STOP when non-zero
         CASE
           WHEN LENGTH(TRIM(NVL(p.partition_info, ''))) > 0 THEN
             '  -> Partition: ' || TRIM(p.partition_info) ||
             CASE
               WHEN NVL(p.partition_start, 0) <> 0 OR NVL(p.partition_stop, 0) <> 0
               THEN ' (' || NVL(TO_CHAR(p.partition_start), '?') || '..' ||
                    NVL(TO_CHAR(p.partition_stop), '?') || ')'
               ELSE ''
             END
           WHEN NVL(p.partition_start, 0) <> 0 OR NVL(p.partition_stop, 0) <> 0 THEN
             '  -> Partition: ' ||
             NVL(TO_CHAR(p.partition_start), '?') || '..' ||
             NVL(TO_CHAR(p.partition_stop), '?')
         END AS part_txt,
         CASE
           WHEN LENGTH(TRIM(NVL(p.other_tag, ''))) > 0
           THEN '  -> Other: ' || TRIM(p.other_tag)
         END AS other_txt,
         CASE
           WHEN NVL(p.temp_space, 0) <> 0
           THEN '  -> Temp: ' || TO_CHAR(p.temp_space)
         END AS temp_txt,
         CASE
           WHEN NVL(p.search_columns, 0) <> 0
           THEN '  -> SearchCols: ' || TO_CHAR(p.search_columns)
         END AS search_txt,
         CASE
           WHEN NVL(p.cpu_cost, 0) <> 0 OR NVL(p.io_cost, 0) <> 0
           THEN '  -> CpuIo: cpu=' || NVL(TO_CHAR(p.cpu_cost), '0') ||
                ' io=' || NVL(TO_CHAR(p.io_cost), '0')
         END AS cpuio_txt,
         CASE
           WHEN LENGTH(TRIM(NVL(p.projection, ''))) > 0
           THEN '  -> Projection: ' || p.projection
         END AS proj_txt,
         ROW_NUMBER() OVER (
           PARTITION BY p.plan_hash_value, p.id
           ORDER BY p.child_number NULLS LAST, p.child_address, p.address
         ) AS rn
    FROM v$sql_plan p
   WHERE p.sql_id = '&&sqlid'
     AND p.id IS NOT NULL
     AND p.operation IS NOT NULL
),
base AS (
  SELECT phv, id, parent_id, depth, operation, options,
         object_owner, object_name, object_type, object_alias,
         cost, cardinality, bytes, plan_time, cpu_cost, io_cost,
         search_columns, access_predicates, filter_predicates, projection,
         partition_info, partition_start, partition_stop, other_tag, temp_space,
         op_txt, name_txt, access_txt, filter_txt, part_txt, other_txt,
         temp_txt, search_txt, cpuio_txt, proj_txt
    FROM ranked
   WHERE rn = 1
),
w AS (
  SELECT phv,
         GREATEST(LENGTH('Id'), NVL(MAX(LENGTH(TO_CHAR(id))), 0)) AS w_id,
         GREATEST(LENGTH('Pid'), NVL(MAX(LENGTH(TO_CHAR(parent_id))), 0)) AS w_pid,
         GREATEST(LENGTH('Ord'), NVL(MAX(LENGTH(TO_CHAR(id))), 0)) AS w_ord,
         LEAST(
           120,
           GREATEST(
             LENGTH('Operation'),
             NVL(MAX(LENGTH(op_txt)), 0),
             NVL(MAX(LENGTH(access_txt)), 0),
             NVL(MAX(LENGTH(filter_txt)), 0),
             NVL(MAX(LENGTH(part_txt)), 0),
             NVL(MAX(LENGTH(other_txt)), 0),
             NVL(MAX(LENGTH(temp_txt)), 0),
             NVL(MAX(LENGTH(search_txt)), 0),
             NVL(MAX(LENGTH(cpuio_txt)), 0),
             NVL(MAX(LENGTH(proj_txt)), 0)
           )
         ) AS w_op,
         LEAST(120, GREATEST(LENGTH('Name'), NVL(MAX(LENGTH(name_txt)), 0))) AS w_name,
         GREATEST(LENGTH('Rows'), NVL(MAX(LENGTH(TO_CHAR(cardinality))), 0)) AS w_rows,
         GREATEST(LENGTH('Bytes'), NVL(MAX(LENGTH(TO_CHAR(bytes))), 0)) AS w_bytes,
         GREATEST(LENGTH('Cost'), NVL(MAX(LENGTH(TO_CHAR(cost))), 0)) AS w_cost,
         GREATEST(LENGTH('Time'), NVL(MAX(LENGTH(TO_CHAR(plan_time))), 0)) AS w_time
    FROM base
   GROUP BY phv
),
phvs AS (
  SELECT DISTINCT phv FROM base
),
lines AS (
  SELECT p.phv,
         0 AS sek,
         0 AS sid,
         '============================================================================' AS plan_line
    FROM phvs p
  UNION ALL
  SELECT p.phv, 1, 0,
         'Plan Hash Value: ' || TO_CHAR(p.phv)
    FROM phvs p
  UNION ALL
  SELECT p.phv, 2, 0,
         '============================================================================'
    FROM phvs p
  UNION ALL
  SELECT p.phv, 4, 0,
         '|' || LPAD('Id', w.w_id) || '|' ||
         LPAD('Pid', w.w_pid) || '|' ||
         LPAD('Ord', w.w_ord) || '|' ||
         RPAD('Operation', w.w_op) || '|' ||
         RPAD('Name', w.w_name) || '|' ||
         RPAD('Rows', w.w_rows) || '|' ||
         RPAD('Bytes', w.w_bytes) || '|' ||
         RPAD('Cost', w.w_cost) || '|' ||
         RPAD('Time', w.w_time) || '|'
    FROM phvs p
    JOIN w ON w.phv = p.phv
  UNION ALL
  SELECT p.phv, 5, 0,
         '|' || LPAD('-', w.w_id, '-') || '|' ||
         LPAD('-', w.w_pid, '-') || '|' ||
         LPAD('-', w.w_ord, '-') || '|' ||
         RPAD('-', w.w_op, '-') || '|' ||
         RPAD('-', w.w_name, '-') || '|' ||
         RPAD('-', w.w_rows, '-') || '|' ||
         RPAD('-', w.w_bytes, '-') || '|' ||
         RPAD('-', w.w_cost, '-') || '|' ||
         RPAD('-', w.w_time, '-') || '|'
    FROM phvs p
    JOIN w ON w.phv = p.phv
  UNION ALL
  SELECT b.phv, 6, b.id * 20,
         '|' || LPAD(TO_CHAR(b.id), w.w_id) || '|' ||
         LPAD(NVL(TO_CHAR(b.parent_id), ' '), w.w_pid) || '|' ||
         LPAD(TO_CHAR(b.id), w.w_ord) || '|' ||
         RPAD(SUBSTR(NVL(b.op_txt, ' '), 1, w.w_op), w.w_op) || '|' ||
         RPAD(SUBSTR(NVL(b.name_txt, ' '), 1, w.w_name), w.w_name) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.cardinality), ' '), 1, w.w_rows), w.w_rows) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.bytes), ' '), 1, w.w_bytes), w.w_bytes) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.cost), ' '), 1, w.w_cost), w.w_cost) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.plan_time), ' '), 1, w.w_time), w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 1,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.access_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.access_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 2,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.filter_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.filter_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 3,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.part_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.part_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 4,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.other_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.other_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 5,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.temp_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.temp_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 6,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.search_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.search_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 7,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.cpuio_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.cpuio_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 8,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.proj_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.proj_txt IS NOT NULL
  UNION ALL
  SELECT p.phv, 7, 0,
         '============================================================================'
    FROM phvs p
),
empty_msg AS (
  SELECT CAST(NULL AS NUMBER) AS phv,
         0 AS sek,
         0 AS sid,
         'No plan found in V$SQL_PLAN for sql_id=&&sqlid' AS plan_line
    FROM dual
   WHERE NOT EXISTS (SELECT 1 FROM base)
)
SELECT plan_line
  FROM (
        SELECT phv, sek, sid, plan_line FROM lines
        UNION ALL
        SELECT phv, sek, sid, plan_line FROM empty_msg
       )
 ORDER BY phv NULLS LAST, sek, sid
/


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from v$sqlarea                |
PROMPT +------------------------------------------------------------------------+
PROMPT

col  EXEC                   for   a8
col  CPU_P_E                for   a10
col  ELA_P_E                for   a10
col  DISK_P_E               for   a10
col  GET_P_E                for   a10
col  ROWS_P_E               for   a10
col  APP_W_P                for   a10
col  CLU_W_P                for   a10
col  IO_W_P                 for   a10
col  ROWS_P_F               for   a10
col  CON_W_P                for   a10
col  PLSQL_W_P              for   a10
col  OUTLINE                for   a20
col  F_L_TIME               for   a15
col  APP_P_E                for   a10
col  CON_P_E                for   a10
col  USERNAME               for   a15
col  C                      for   a3
col  PHV                    for   a12
col  IOW_P_E                for   a10
col  WRITE_P_E              for   a10
col  i                      for   a1
col  SORTS_P_E              for   a10
col  SEGMENT_NAME           for   a25

SELECT PLAN_HASH_VALUE||'' PHV,
        CASE
        WHEN EXECUTIONS < 1000 THEN TO_CHAR(EXECUTIONS)
        WHEN EXECUTIONS < 10000 THEN TO_CHAR(ROUND(EXECUTIONS / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(EXECUTIONS / 10000, 2)) || 'W'
        END AS EXEC,
       CASE
        WHEN CPU_TIME IS NULL THEN NULL
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
        END AS CPU_P_E,
       CASE
        WHEN ELAPSED_TIME IS NULL THEN NULL
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
        END AS ELA_P_E,
       CASE
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
        END AS DISK_P_E,
       CASE
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS GET_P_E,
       CASE
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS ROWS_P_E,
       CASE
        WHEN fetches/ DECODE(executions, 0, 1, executions) < 1000 THEN TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions),2))
        WHEN fetches / DECODE(executions, 0, 1, executions) < 10000 THEN TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions) / 10000, 2)) || 'W'
        END AS ROWS_P_F,
      CASE
        WHEN APPLICATION_WAIT_TIME IS NULL THEN NULL
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS APP_W_P,
        CASE
        WHEN CONCURRENCY_WAIT_TIME IS NULL THEN NULL
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CON_W_P,
         case
               WHEN CLUSTER_WAIT_TIME IS NULL THEN NULL
               WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CLU_W_P,
               CASE
        WHEN USER_IO_WAIT_TIME IS NULL THEN NULL
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS IO_W_P,
    CASE
        WHEN PLSQL_EXEC_TIME IS NULL THEN NULL
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS PLSQL_W_P,
    CAST(NULL AS VARCHAR(64)) AS outline
  FROM v$sqlarea
where sql_id = '&&sqlid';

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from v$sql                 |
PROMPT +------------------------------------------------------------------------+
PROMPT


SELECT
    CASE
        WHEN EXECUTIONS < 1000 THEN TO_CHAR(EXECUTIONS)
        WHEN EXECUTIONS < 10000 THEN TO_CHAR(ROUND(EXECUTIONS / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(EXECUTIONS / 10000, 2)) || 'W'
    END AS EXEC,
    PLAN_HASH_VALUE||'' PHV,
    child_number||'' AS c,
    PARSING_SCHEMA_NAME AS username,
      CASE
        WHEN CPU_TIME IS NULL THEN NULL
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CPU_P_E,
    CASE
        WHEN ELAPSED_TIME IS NULL THEN NULL
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS ELA_P_E,
    CASE
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS DISK_P_E,
    CASE
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS GET_P_E,
    CASE
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS ROWS_P_E,
    CASE
        WHEN ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES),2))
        WHEN ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) / 10000, 2)) || 'W'
    END AS ROWS_P_F,
  CASE
        WHEN APPLICATION_WAIT_TIME IS NULL THEN NULL
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS APP_P_E,
        CASE
        WHEN CONCURRENCY_WAIT_TIME IS NULL THEN NULL
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CON_P_E,
        CASE
        WHEN CLUSTER_WAIT_TIME IS NULL THEN NULL
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CLU_W_P,
        CASE
        WHEN USER_IO_WAIT_TIME IS NULL THEN NULL
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS IO_W_P,
        CASE
        WHEN PLSQL_EXEC_TIME IS NULL THEN NULL
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS PLSQL_W_P,
    SUBSTR(FIRST_LOAD_TIME, 6, 10) || '.' || SUBSTR(LAST_LOAD_TIME, 6, 10) AS f_l_time
FROM v$sql s
WHERE sql_id = '&&sqlid'
ORDER BY plan_hash_value;


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from awr (END_INTERVAL_TIME > SYSDATE-5)                  |
PROMPT +------------------------------------------------------------------------+
PROMPT

SELECT TO_CHAR (END_INTERVAL_TIME, 'dd hh24') end_time,
         TRIM (a.instance_number) i,
         a.parsing_schema_name as username,
         a.plan_hash_value||'' PHV,
      CASE
        WHEN executions_delta < 1000 THEN TO_CHAR(executions_delta)
        WHEN executions_delta < 10000 THEN TO_CHAR(ROUND(executions_delta / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(executions_delta / 10000, 2)) || 'W'
    END AS EXEC,
    CASE
        WHEN cpu_time_delta IS NULL THEN NULL
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CPU_P_E,
    CASE
        WHEN elapsed_time_delta IS NULL THEN NULL
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS ELA_P_E,
    CASE
        WHEN disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS DISK_P_E,
        CASE
        WHEN BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS GET_P_E,
    CASE
        WHEN rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS ROWS_P_E,
    CASE
        WHEN fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS ROWS_P_F,
    CASE
        WHEN direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS WRITE_P_E,
    CASE
        WHEN IOWAIT_DELTA IS NULL THEN NULL
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS IOW_P_E,
    -- CASE
    --     WHEN parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
    --     WHEN parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
    --     ELSE TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    -- END AS PARSE_P_E,
    CASE
        WHEN sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS SORTS_P_E,
    CASE
        WHEN apwait_delta IS NULL THEN NULL
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS APP_P_E,
    CASE
        WHEN ccwait_delta IS NULL THEN NULL
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CON_P_E,
    CASE
        WHEN clwait_delta IS NULL THEN NULL
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CLU_W_P,
    CASE
        WHEN plsexec_time_delta IS NULL THEN NULL
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS PLSQL_W_P
    FROM WRH$_SQLSTAT  a, WRM$_SNAPSHOT b
   WHERE     a.sql_id = '&&sqlid'
         AND a.snap_id = b.snap_id
         AND b.END_INTERVAL_TIME > SYSDATE - 5
         AND a.instance_number = b.instance_number
ORDER BY 1
/


prompt
prompt ****************************************************************************************
prompt OBJECT SIZE
prompt ****************************************************************************************
-- Object resolution: small v$sql_plan set -> tbl (index->table UNION table), then JOIN.
-- Avoid (owner,name) IN (UNION dba_indexes/dba_tables) semi-join explosion.
-- seg = [***]owner.name  (*** = table)

col seg                for   a50
col typ                for   a18
col sz                 for   a8

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
),
objs AS (
  SELECT owner, name AS segment_name FROM t
  UNION
  SELECT owner, table_name FROM tbl
)
SELECT CASE WHEN EXISTS (
              SELECT 1 FROM tbl tt
               WHERE tt.owner = b.owner AND tt.table_name = b.segment_name
            )
            THEN '***' ELSE '' END
       || b.owner || '.' || b.segment_name AS seg,
       b.segment_type AS typ,
       TRUNC(b.bytes / 1024 / 1024) || 'M' AS sz
  FROM (
        SELECT s.owner, s.segment_name, s.segment_type, SUM(s.bytes) AS bytes
          FROM dba_segments s
          JOIN objs o
            ON s.owner = o.owner
           AND s.segment_name = o.segment_name
         GROUP BY s.owner, s.segment_type, s.segment_name
       ) b
 ORDER BY b.owner, b.segment_name
/



prompt
prompt ****************************************************************************************
prompt TABLES
prompt ****************************************************************************************

col tab                for a40
col l_t                for a5
col degree             for a6
col part               for a4
col nrows              for a8
col blks               for a8
col eblks              for a6
col avg_sp             for a6
col avg_rlen           for a6
col blk_mb             for a8
col avg_mb             for a8
col stale              for a5
col last_analyzed      for a19

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.owner || '.' || a.table_name AS tab,
       a.logging || '.' || a.temporary AS l_t,
       LTRIM(a.degree) AS degree,
       a.partitioned AS part,
       CASE
         WHEN a.num_rows IS NULL THEN NULL
         WHEN a.num_rows < 1000 THEN TO_CHAR(a.num_rows)
         WHEN a.num_rows < 1000000 THEN TO_CHAR(ROUND(a.num_rows / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(a.num_rows / 1000000, 2)) || 'M'
       END AS nrows,
       CASE
         WHEN a.blocks IS NULL THEN NULL
         WHEN a.blocks < 1000 THEN TO_CHAR(a.blocks)
         WHEN a.blocks < 1000000 THEN TO_CHAR(ROUND(a.blocks / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(a.blocks / 1000000, 2)) || 'M'
       END AS blks,
       CASE
         WHEN a.empty_blocks IS NULL THEN NULL
         WHEN a.empty_blocks < 1000 THEN TO_CHAR(a.empty_blocks)
         WHEN a.empty_blocks < 1000000 THEN TO_CHAR(ROUND(a.empty_blocks / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(a.empty_blocks / 1000000, 2)) || 'M'
       END AS eblks,
       b.avg_space || '' AS avg_sp,
       b.avg_row_len || '' AS avg_rlen,
       TRUNC((b.blocks * tp.block_size) / 1024 / 1024) || 'M' AS blk_mb,
       TRUNC((b.avg_row_len * b.num_rows) / 1024 / 1024) || 'M' AS avg_mb,
       b.stale_stats || '' AS stale,
       TO_CHAR(a.last_analyzed, 'yyyy-mm-dd hh24:mi:ss') AS last_analyzed
  FROM tbl x
  JOIN dba_tables a
    ON a.owner = x.owner AND a.table_name = x.table_name
  LEFT JOIN dba_tab_statistics b
    ON b.owner = a.owner
   AND b.table_name = a.table_name
   AND b.object_type = 'TABLE'
  LEFT JOIN dba_tablespaces tp
    ON tp.tablespace_name = a.tablespace_name
 ORDER BY a.owner, a.table_name
/



prompt
prompt ****************************************************************************************
prompt TABLE COLUMNS
prompt ****************************************************************************************
-- tab = owner.table; col_type = column_name(datatype(len)); counts use K/M units

col tab                for a40
col col_type           for a40
col ndist              for a8
col n                  for a1
col nnulls             for a8
col density            for a12
col nbucket            for a6
col avg_len            for a6
col sample             for a8
col hist               for a5
col last_analyzed      for a19

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.owner || '.' || a.table_name AS tab,
       a.column_name || '(' || a.data_type || '(' || a.data_length || '))' AS col_type,
       CASE
         WHEN b.num_distinct IS NULL THEN NULL
         WHEN b.num_distinct < 1000 THEN TO_CHAR(b.num_distinct)
         WHEN b.num_distinct < 1000000 THEN TO_CHAR(ROUND(b.num_distinct / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(b.num_distinct / 1000000, 2)) || 'M'
       END AS ndist,
       a.nullable || '' AS n,
       CASE
         WHEN b.num_nulls IS NULL THEN NULL
         WHEN b.num_nulls < 1000 THEN TO_CHAR(b.num_nulls)
         WHEN b.num_nulls < 1000000 THEN TO_CHAR(ROUND(b.num_nulls / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(b.num_nulls / 1000000, 2)) || 'M'
       END AS nnulls,
       TO_CHAR(b.density, 'FM999999999990.999999999999') AS density,
       CASE
         WHEN b.num_buckets IS NULL THEN NULL
         WHEN b.num_buckets < 1000 THEN TO_CHAR(b.num_buckets)
         WHEN b.num_buckets < 1000000 THEN TO_CHAR(ROUND(b.num_buckets / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(b.num_buckets / 1000000, 2)) || 'M'
       END AS nbucket,
       b.avg_col_len || '' AS avg_len,
       CASE
         WHEN b.sample_size IS NULL THEN NULL
         WHEN b.sample_size < 1000 THEN TO_CHAR(b.sample_size)
         WHEN b.sample_size < 1000000 THEN TO_CHAR(ROUND(b.sample_size / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(b.sample_size / 1000000, 2)) || 'M'
       END AS sample,
       SUBSTR(b.histogram, 1, 5) AS hist,
       TO_CHAR(b.last_analyzed, 'yyyy-mm-dd hh24:mi:ss') AS last_analyzed
  FROM tbl x
  JOIN dba_tab_cols a
    ON a.owner = x.owner AND a.table_name = x.table_name
  LEFT JOIN dba_tab_col_statistics b
    ON b.owner = a.owner
   AND b.table_name = a.table_name
   AND b.column_name = a.column_name
 ORDER BY a.owner, a.table_name, a.column_id
/



prompt
prompt ****************************************************************************************
prompt INDEX STATUS
prompt ****************************************************************************************

col idx                    for a50
col PARTITION_NAME         for a20
col SUBPARTITION_NAME      for a20
col status                 for a10

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
),
tt AS (
  SELECT i.owner,
         i.index_name,
         i.status,
         i.partitioned
    FROM dba_indexes i
    JOIN tbl x
      ON i.table_owner = x.owner
     AND i.table_name = x.table_name
   WHERE i.status NOT IN ('VALID')
)
SELECT owner || '.' || index_name AS idx,
       '' AS partition_name,
       '' AS subpartition_name,
       status
  FROM tt
 WHERE tt.partitioned = 'NO'
UNION ALL
SELECT p.index_owner || '.' || p.index_name AS idx,
       p.partition_name,
       '' AS subpartition_name,
       p.status
  FROM dba_ind_partitions p
  JOIN tt
    ON p.index_owner = tt.owner
   AND p.index_name = tt.index_name
 WHERE tt.partitioned = 'YES'
   AND p.status NOT IN ('USABLE')
UNION ALL
SELECT p.index_owner || '.' || p.index_name AS idx,
       p.partition_name,
       p.subpartition_name,
       p.status
  FROM dba_ind_subpartitions p
  JOIN tt
    ON p.index_owner = tt.owner
   AND p.index_name = tt.index_name
 WHERE tt.partitioned = 'YES'
   AND p.status NOT IN ('USABLE')
 ORDER BY 1, 2, 3, 4
/

prompt
prompt ****************************************************************************************
prompt INDEX INFO
prompt ****ucptdvs "UNIQUENESS COMPRESSION PARTITIONED TEMPORARY  VISIBILITY                "**
prompt ****************************************************************************************

col tab                for a40
col idx                for a64
col ucptv              for a6
col col_pos            for a28
col descend            for a4

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.table_owner || '.' || a.table_name AS tab,
       a.index_name AS idx,
          DECODE(a.uniqueness,  'UNIQUE', 'U',  'NONUNIQUE', 'N',  'O')
       || DECODE(a.compression, 'ENABLED', 'E',  'DISABLED', 'N',  'O')
       || DECODE(a.partitioned, 'YES', 'Y',  'NO', 'N',  'O')
       || DECODE(a.temporary,  'Y', 'Y',  'N', 'N',  'O')
       || DECODE(a.visibility, 'VISIBLE', 'V',  'INVISIBLE', 'I',  'O') AS ucptv,
       b.column_name || '(' || b.column_position || ')' AS col_pos,
       b.descend
  FROM tbl x
  JOIN dba_indexes a
    ON a.table_owner = x.owner
   AND a.table_name = x.table_name
  JOIN dba_ind_columns b
    ON a.owner = b.index_owner
   AND a.index_name = b.index_name
 ORDER BY a.table_owner, a.table_name, a.index_name, b.column_position
/


prompt
prompt ****************************************************************************************
prompt PARTITION INDEX
prompt ****************************************************************************************

col idx                for a50
col part_type          for a10
col subpart_type       for a10
col locality           for a10
col col_pos            for a28

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.owner || '.' || a.name AS idx,
       b.partitioning_type AS part_type,
       b.subpartitioning_type AS subpart_type,
       b.partition_count || '' AS part_cnt,
       b.partitioning_key_count || '' AS key_cnt,
       b.subpartitioning_key_count || '' AS subkey_cnt,
       b.locality,
       a.column_name || '(' || a.column_position || ')' AS col_pos
  FROM dba_part_key_columns a
  JOIN dba_part_indexes b
    ON a.owner = b.owner
   AND a.name = b.index_name
  JOIN dba_indexes i
    ON i.owner = b.owner
   AND i.index_name = b.index_name
  JOIN tbl x
    ON i.table_owner = x.owner
   AND i.table_name = x.table_name
 ORDER BY a.owner, a.name, a.column_position
/


prompt
prompt ****************************************************************************************
prompt PARTITION TABLE
prompt ****************************************************************************************

col tab                for a40
col part_type          for a10
col subpart_type       for a10
col col_pos            for a28

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.owner || '.' || a.name AS tab,
       b.partitioning_type AS part_type,
       b.subpartitioning_type AS subpart_type,
       b.partition_count || '' AS part_cnt,
       b.partitioning_key_count || '' AS key_cnt,
       b.subpartitioning_key_count || '' AS subkey_cnt,
       a.column_name || '(' || a.column_position || ')' AS col_pos
  FROM dba_part_key_columns a
  JOIN dba_part_tables b
    ON a.owner = b.owner
   AND a.name = b.table_name
  JOIN tbl x
    ON a.owner = x.owner
   AND a.name = x.table_name
 ORDER BY a.name, a.column_position
/



prompt
prompt ****************************************************************************************
prompt display every partition  info
prompt ****************************************************************************************

col tab                     for a40
col partition_name          for a20
col high_value              for a25
col ts                      for a15
col nrows                   for a8
col blks                    for a8
col t_size                  for a10
col eblks                   for a6
col last_analyzed           for a19
col avg_sp                  for a6
col spcnt                   for a5

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT p.table_owner || '.' || p.table_name AS tab,
       p.partition_name,
       p.high_value,
       p.tablespace_name AS ts,
       CASE
         WHEN p.num_rows IS NULL THEN NULL
         WHEN p.num_rows < 1000 THEN TO_CHAR(p.num_rows)
         WHEN p.num_rows < 1000000 THEN TO_CHAR(ROUND(p.num_rows / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(p.num_rows / 1000000, 2)) || 'M'
       END AS nrows,
       CASE
         WHEN p.blocks IS NULL THEN NULL
         WHEN p.blocks < 1000 THEN TO_CHAR(p.blocks)
         WHEN p.blocks < 1000000 THEN TO_CHAR(ROUND(p.blocks / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(p.blocks / 1000000, 2)) || 'M'
       END AS blks,
       ROUND(p.blocks * 8 / 1024, 2) || 'KB' AS t_size,
       CASE
         WHEN p.empty_blocks IS NULL THEN NULL
         WHEN p.empty_blocks < 1000 THEN TO_CHAR(p.empty_blocks)
         WHEN p.empty_blocks < 1000000 THEN TO_CHAR(ROUND(p.empty_blocks / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(p.empty_blocks / 1000000, 2)) || 'M'
       END AS eblks,
       TO_CHAR(p.last_analyzed, 'yyyy-mm-dd hh24:mi:ss') AS last_analyzed,
       p.avg_space || '' AS avg_sp,
       SUBSTR(p.subpartition_count || '', 1, 5) AS spcnt
  FROM dba_tab_partitions p
  JOIN tbl x
    ON p.table_owner = x.owner
   AND p.table_name = x.table_name
 ORDER BY p.table_name, p.partition_position
/




