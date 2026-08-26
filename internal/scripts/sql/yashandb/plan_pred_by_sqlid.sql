-- File Name: plan_pred_by_sqlid.sql
-- Purpose: SQL tuning report like sql.sql with EXPLAIN PLAN FOR and predicates
-- Created: 20260802  by  huangtingzhong
-- Notes:
--   Front: LITERAL SQL, sql.sql PLAN from v$sql_plan, EXPLAIN PLAN FOR paste.
--   Back: v$sqlarea / v$sql / AWR / object sections (same as sql.sql).
--   EXPLAIN PLAN FOR: original sql_fulltext printed for manual re-run (PLAN_DESCRIPTION).
--   Variable: &&sqlid only (all children).

set serveroutput on;
prompt
prompt ****************************************************************************************
prompt plan_pred_by_sqlid  (sql_id = &&sqlid)
prompt ****************************************************************************************
prompt Output: [1/3] LITERAL, [2/3] PLAN from v$sql_plan, [3/3] EXPLAIN PLAN FOR paste.
prompt




DECLARE
  c_sqlid      CONSTANT VARCHAR2(64) := TRIM('&&sqlid');
  -- UTF8: keep chunk small for DBMS_OUTPUT / WRITEAPPEND byte limits
  c_chunk      CONSTANT PLS_INTEGER := 1000;

  lvc_sql_text      CLOB;
  lvc_orig_sql_text CLOB;
  lvc_repl          VARCHAR2(4000);
  lvc_bind          VARCHAR2(200);
  lvc_name          VARCHAR2(128);
  ln_qpos           NUMBER;
  ln_sql_cnt        NUMBER := 0;
  ln_child_cnt      NUMBER := 0;
  ln_err            NUMBER := 0;
  ln_sql_len        NUMBER := 0;

  FUNCTION clob_char(p_clob IN CLOB, p_pos IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_pos < 1 OR p_pos > NVL(DBMS_LOB.GETLENGTH(p_clob), 0) THEN
      RETURN NULL;
    END IF;
    RETURN DBMS_LOB.SUBSTR(p_clob, 1, p_pos);
  END;

  FUNCTION is_ident_char(p_ch IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    IF p_ch IS NULL THEN
      RETURN FALSE;
    END IF;
    RETURN (p_ch >= '0' AND p_ch <= '9')
        OR (UPPER(p_ch) >= 'A' AND UPPER(p_ch) <= 'Z')
        OR p_ch = '_';
  END;

  -- 与 sql.sql 一致: SYS_B 优先 :SYS_B_n, 备选 :"SYS_B_n"
  FUNCTION bind_pattern(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    v_bare VARCHAR2(128);
  BEGIN
    IF p_name IS NULL OR LENGTH(TRIM(p_name)) = 0 OR TRIM(p_name) = '?' THEN
      RETURN NULL;
    END IF;
    IF UPPER(LTRIM(p_name, ':')) LIKE 'SYS_B_%'
       OR UPPER(REPLACE(LTRIM(p_name, ':'), '"', '')) LIKE 'SYS_B_%' THEN
      v_bare := REPLACE(LTRIM(p_name, ':'), '"', '');
      RETURN ':' || v_bare;
    ELSIF p_name LIKE ':%' THEN
      RETURN p_name;
    ELSE
      RETURN ':' || LTRIM(p_name, ':');
    END IF;
  END;

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
  END;

  FUNCTION uses_question_bind_clob(p_clob IN CLOB) RETURN BOOLEAN IS
    v_p   NUMBER := 1;
    v_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    v_inq BOOLEAN := FALSE;
    v_ch  VARCHAR2(8);
  BEGIN
    WHILE v_p <= v_len LOOP
      v_ch := clob_char(p_clob, v_p);
      IF v_ch = '''' THEN
        IF v_inq AND v_p < v_len AND clob_char(p_clob, v_p + 1) = '''' THEN
          v_p := v_p + 2;
        ELSE
          v_inq := NOT v_inq;
          v_p := v_p + 1;
        END IF;
      ELSIF NOT v_inq AND v_ch = '?' THEN
        RETURN TRUE;
      ELSE
        v_p := v_p + 1;
      END IF;
    END LOOP;
    RETURN FALSE;
  END;

  FUNCTION find_question_clob(p_clob IN CLOB) RETURN NUMBER IS
    v_p   NUMBER := 1;
    v_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    v_inq BOOLEAN := FALSE;
    v_ch  VARCHAR2(8);
  BEGIN
    WHILE v_p <= v_len LOOP
      v_ch := clob_char(p_clob, v_p);
      IF v_ch = '''' THEN
        IF v_inq AND v_p < v_len AND clob_char(p_clob, v_p + 1) = '''' THEN
          v_p := v_p + 2;
        ELSE
          v_inq := NOT v_inq;
          v_p := v_p + 1;
        END IF;
      ELSIF NOT v_inq AND v_ch = '?' THEN
        RETURN v_p;
      ELSE
        v_p := v_p + 1;
      END IF;
    END LOOP;
    RETURN 0;
  END;

  FUNCTION find_pattern_clob(p_clob IN CLOB, p_pattern IN VARCHAR2) RETURN NUMBER IS
    v_p    NUMBER := 1;
    v_len  NUMBER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    v_plen NUMBER := NVL(LENGTH(p_pattern), 0);
    v_inq  BOOLEAN := FALSE;
    v_ch   VARCHAR2(8);
    v_next VARCHAR2(8);
    v_frag VARCHAR2(4000);
  BEGIN
    IF v_plen = 0 OR v_plen > 4000 THEN
      RETURN 0;
    END IF;
    WHILE v_p <= v_len LOOP
      v_ch := clob_char(p_clob, v_p);
      IF v_ch = '''' THEN
        IF v_inq AND v_p < v_len AND clob_char(p_clob, v_p + 1) = '''' THEN
          v_p := v_p + 2;
        ELSE
          v_inq := NOT v_inq;
          v_p := v_p + 1;
        END IF;
      ELSIF NOT v_inq AND v_p + v_plen - 1 <= v_len THEN
        v_frag := DBMS_LOB.SUBSTR(p_clob, v_plen, v_p);
        IF UPPER(v_frag) = UPPER(p_pattern) THEN
          v_next := clob_char(p_clob, v_p + v_plen);
          IF p_pattern LIKE ':%' AND is_ident_char(v_next) THEN
            v_p := v_p + 1;
          ELSE
            RETURN v_p;
          END IF;
        ELSE
          v_p := v_p + 1;
        END IF;
      ELSE
        v_p := v_p + 1;
      END IF;
    END LOOP;
    RETURN 0;
  END;

  PROCEDURE clob_splice_replace(
    p_clob        IN OUT NOCOPY CLOB,
    p_start       IN NUMBER,
    p_match_len   IN NUMBER,
    p_replacement IN VARCHAR2
  ) IS
    v_new CLOB;
    v_len NUMBER;
    v_off NUMBER;
    v_amt NUMBER;
    v_buf VARCHAR2(4000);
  BEGIN
    v_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    DBMS_LOB.CREATETEMPORARY(v_new, TRUE);

    v_off := 1;
    WHILE v_off < p_start LOOP
      v_amt := LEAST(c_chunk, p_start - v_off);
      v_buf := DBMS_LOB.SUBSTR(p_clob, v_amt, v_off);
      DBMS_LOB.WRITEAPPEND(v_new, LENGTH(v_buf), v_buf);
      v_off := v_off + v_amt;
    END LOOP;

    IF p_replacement IS NOT NULL AND LENGTH(p_replacement) > 0 THEN
      DBMS_LOB.WRITEAPPEND(v_new, LENGTH(p_replacement), p_replacement);
    END IF;

    v_off := p_start + p_match_len;
    WHILE v_off <= v_len LOOP
      v_amt := LEAST(c_chunk, v_len - v_off + 1);
      v_buf := DBMS_LOB.SUBSTR(p_clob, v_amt, v_off);
      DBMS_LOB.WRITEAPPEND(v_new, LENGTH(v_buf), v_buf);
      v_off := v_off + v_amt;
    END LOOP;

    IF DBMS_LOB.ISTEMPORARY(p_clob) = 1 THEN
      DBMS_LOB.FREETEMPORARY(p_clob);
    END IF;
    p_clob := v_new;
  END;

  PROCEDURE put_clob(p_text IN CLOB) IS
    v_len NUMBER;
    v_off NUMBER := 1;
    v_buf VARCHAR2(4000);
  BEGIN
    IF p_text IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('');
      RETURN;
    END IF;
    v_len := NVL(DBMS_LOB.GETLENGTH(p_text), 0);
    IF v_len = 0 THEN
      DBMS_OUTPUT.PUT_LINE('');
      RETURN;
    END IF;
    WHILE v_off <= v_len LOOP
      v_buf := DBMS_LOB.SUBSTR(p_text, LEAST(c_chunk, v_len - v_off + 1), v_off);
      DBMS_OUTPUT.PUT_LINE(v_buf);
      v_off := v_off + c_chunk;
    END LOOP;
  END;

  PROCEDURE clob_rtrim_sql(p_clob IN OUT NOCOPY CLOB) IS
    v_len NUMBER;
    v_ch  VARCHAR2(8);
  BEGIN
    v_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    WHILE v_len > 0 LOOP
      v_ch := clob_char(p_clob, v_len);
      IF v_ch IN (' ', ';', CHR(10), CHR(13), CHR(9)) THEN
        DBMS_LOB.TRIM(p_clob, v_len - 1);
        v_len := v_len - 1;
      ELSE
        EXIT;
      END IF;
    END LOOP;
  END;

  -- p_sql: original sql_fulltext (with ? / :binds); do not pass literalized SQL
  PROCEDURE emit_explain_block(
    p_schema IN VARCHAR2,
    p_child  IN NUMBER,
    p_sql    IN CLOB
  ) IS
    v_sql CLOB := p_sql;
  BEGIN
    clob_rtrim_sql(v_sql);

    IF p_schema IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('ALTER SESSION SET CURRENT_SCHEMA = ' || p_schema || ';');
    END IF;
    DBMS_OUTPUT.PUT_LINE('EXPLAIN PLAN FOR');
    put_clob(v_sql);
    DBMS_OUTPUT.PUT_LINE(';');
  END;

  PROCEDURE emit_literal_section(
    p_schema IN VARCHAR2,
    p_child  IN NUMBER,
    p_sql_len IN NUMBER,
    p_literal IN CLOB
  ) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE(
      '****************************************************************************************');
    DBMS_OUTPUT.PUT_LINE(
      '[1/3] LITERAL SQL (binds replaced)  sql_id=' || c_sqlid
      || '  child#=' || TO_CHAR(p_child)
      || '  schema=' || NVL(p_schema, '(null)'));
    DBMS_OUTPUT.PUT_LINE(
      '      sql_len=' || TO_CHAR(p_sql_len)
      || '  literal_len=' || TO_CHAR(NVL(DBMS_LOB.GETLENGTH(p_literal), 0)));
    DBMS_OUTPUT.PUT_LINE(
      '****************************************************************************************');
    put_clob(p_literal);
  END;

  PROCEDURE emit_explain_section(
    p_schema IN VARCHAR2,
    p_child  IN NUMBER,
    p_orig   IN CLOB
  ) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE(
      '****************************************************************************************');
    DBMS_OUTPUT.PUT_LINE(
      '[3/3] EXPLAIN PLAN FOR paste (predicates)  sql_id=' || c_sqlid
      || '  child#=' || TO_CHAR(p_child)
      || '  schema=' || NVL(p_schema, '(null)'));
    DBMS_OUTPUT.PUT_LINE(
      '      Keep ? / :binds. ytop -f auto-runs this block for PLAN_DESCRIPTION (Param).');
    DBMS_OUTPUT.PUT_LINE(
      '****************************************************************************************');
    emit_explain_block(p_schema, p_child, p_orig);
  END;


BEGIN
  SELECT COUNT(*)
    INTO ln_sql_cnt
    FROM v$sql
   WHERE sql_id = c_sqlid;

  IF ln_sql_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No SQL found in V$SQL for sql_id=' || c_sqlid);
    RETURN;
  END IF;

  FOR c IN (
    SELECT child_number,
           parsing_schema_name,
           sql_fulltext
      FROM (
            SELECT child_number,
                   parsing_schema_name,
                   sql_fulltext,
                   ROW_NUMBER() OVER (
                     PARTITION BY child_number
                     ORDER BY last_load_time DESC NULLS LAST,
                              child_address,
                              address
                   ) AS rn
              FROM v$sql
             WHERE sql_id = c_sqlid
           )
     WHERE rn = 1
     ORDER BY child_number
  ) LOOP
    ln_child_cnt := ln_child_cnt + 1;
    lvc_name := c.parsing_schema_name;
    ln_err := 0;

    IF DBMS_LOB.ISTEMPORARY(lvc_orig_sql_text) = 1 THEN
      DBMS_LOB.FREETEMPORARY(lvc_orig_sql_text);
    END IF;
    IF DBMS_LOB.ISTEMPORARY(lvc_sql_text) = 1 THEN
      DBMS_LOB.FREETEMPORARY(lvc_sql_text);
    END IF;

    DBMS_LOB.CREATETEMPORARY(lvc_orig_sql_text, TRUE);
    DBMS_LOB.CREATETEMPORARY(lvc_sql_text, TRUE);
    IF c.sql_fulltext IS NOT NULL THEN
      DBMS_LOB.APPEND(lvc_orig_sql_text, c.sql_fulltext);
      DBMS_LOB.APPEND(lvc_sql_text, c.sql_fulltext);
    END IF;
    ln_sql_len := NVL(DBMS_LOB.GETLENGTH(lvc_sql_text), 0);

    -- 去重: v$sql_bind_capture 可能对同一 position 有多行
    FOR r1 IN (
      SELECT name,
             position,
             datatype_string,
             value_string
        FROM (
              SELECT name,
                     position,
                     datatype_string,
                     value_string,
                     ROW_NUMBER() OVER (
                       PARTITION BY position, name
                       ORDER BY value_string NULLS LAST
                     ) AS rn
                FROM v$sql_bind_capture
               WHERE sql_id = c_sqlid
                 AND child_number = c.child_number
             )
       WHERE rn = 1
       ORDER BY position
    ) LOOP
      IF r1.value_string IS NULL THEN
        lvc_repl := 'NULL';
      ELSIF r1.datatype_string = 'NUMBER' THEN
        lvc_repl := r1.value_string;
      ELSIF r1.datatype_string = 'DATE' THEN
        lvc_repl := 'to_date(''' || r1.value_string || ''')';
      ELSIF r1.datatype_string LIKE 'TIMESTAMP%' THEN
        lvc_repl := 'to_timestamp(''' || r1.value_string || ''')';
      ELSE
        lvc_repl := '''' || REPLACE(r1.value_string, '''', '''''') || '''';
      END IF;

      lvc_bind := bind_pattern(r1.name);

      IF lvc_bind IS NOT NULL AND NOT uses_question_bind_clob(lvc_orig_sql_text) THEN
        ln_qpos := find_pattern_clob(lvc_sql_text, lvc_bind);
        IF ln_qpos = 0 AND bind_pattern_alt(r1.name) IS NOT NULL THEN
          lvc_bind := bind_pattern_alt(r1.name);
          ln_qpos := find_pattern_clob(lvc_sql_text, lvc_bind);
        END IF;
        IF ln_qpos = 0 THEN
          ln_qpos := find_question_clob(lvc_sql_text);
          IF ln_qpos = 0 THEN
            DBMS_OUTPUT.PUT_LINE(
              'ERROR: bind pattern not found. '
              || 'child#=' || TO_CHAR(c.child_number)
              || ' position=' || TO_CHAR(r1.position)
              || ' name=' || NVL(r1.name, '(null)')
              || ' pattern=' || NVL(bind_pattern(r1.name), '(null)')
            );
            ln_err := 1;
            EXIT;
          END IF;
          clob_splice_replace(lvc_sql_text, ln_qpos, 1, lvc_repl);
        ELSE
          clob_splice_replace(lvc_sql_text, ln_qpos, LENGTH(lvc_bind), lvc_repl);
        END IF;
      ELSE
        ln_qpos := find_question_clob(lvc_sql_text);
        IF ln_qpos = 0 THEN
          DBMS_OUTPUT.PUT_LINE(
            'ERROR: no remaining ''?'' placeholders while replacing binds. '
            || 'child#=' || TO_CHAR(c.child_number)
            || ' position=' || TO_CHAR(r1.position)
            || ' name=' || NVL(r1.name, '(null)')
          );
          ln_err := 1;
          EXIT;
        END IF;
        clob_splice_replace(lvc_sql_text, ln_qpos, 1, lvc_repl);
      END IF;
    END LOOP;

    IF ln_err = 0 THEN
      emit_literal_section(lvc_name, c.child_number, ln_sql_len, lvc_sql_text);
    ELSE
      DBMS_OUTPUT.PUT_LINE(
        'WARN: LITERAL SQL skipped (bind replace failed).');
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('-- children processed (LITERAL): ' || TO_CHAR(ln_child_cnt));
END;

prompt ****************************************************************************************
prompt [2/3] PLAN from v$sql_plan (sql.sql layout: Id|Pid|Ord|Operation|Name)
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

/





DECLARE
  c_sqlid CONSTANT VARCHAR2(64) := TRIM('&&sqlid');

  lvc_orig CLOB;
  lvc_name VARCHAR2(128);
  ln_cnt NUMBER := 0;
  c_chunk CONSTANT PLS_INTEGER := 1000;

  FUNCTION clob_char(p_clob IN CLOB, p_pos IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_pos < 1 OR p_pos > NVL(DBMS_LOB.GETLENGTH(p_clob), 0) THEN
      RETURN NULL;
    END IF;
    RETURN DBMS_LOB.SUBSTR(p_clob, 1, p_pos);
  END;

  PROCEDURE clob_rtrim_sql(p_clob IN OUT NOCOPY CLOB) IS
    v_len NUMBER;
    v_ch  VARCHAR2(8);
  BEGIN
    v_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    WHILE v_len > 0 LOOP
      v_ch := clob_char(p_clob, v_len);
      IF v_ch IN (' ', ';', CHR(10), CHR(13), CHR(9)) THEN
        DBMS_LOB.TRIM(p_clob, v_len - 1);
        v_len := v_len - 1;
      ELSE
        EXIT;
      END IF;
    END LOOP;
  END;

  PROCEDURE put_clob(p_text IN CLOB) IS
    v_len NUMBER;
    v_off NUMBER := 1;
    v_buf VARCHAR2(4000);
  BEGIN
    IF p_text IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('');
      RETURN;
    END IF;
    v_len := NVL(DBMS_LOB.GETLENGTH(p_text), 0);
    IF v_len = 0 THEN
      DBMS_OUTPUT.PUT_LINE('');
      RETURN;
    END IF;
    WHILE v_off <= v_len LOOP
      v_buf := DBMS_LOB.SUBSTR(p_text, LEAST(c_chunk, v_len - v_off + 1), v_off);
      DBMS_OUTPUT.PUT_LINE(v_buf);
      v_off := v_off + c_chunk;
    END LOOP;
  END;

  PROCEDURE emit_explain_block(
    p_schema IN VARCHAR2,
    p_child  IN NUMBER,
    p_sql    IN CLOB
  ) IS
    v_sql CLOB := p_sql;
  BEGIN
    clob_rtrim_sql(v_sql);

    IF p_schema IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('ALTER SESSION SET CURRENT_SCHEMA = ' || p_schema || ';');
    END IF;
    DBMS_OUTPUT.PUT_LINE('EXPLAIN PLAN FOR');
    put_clob(v_sql);
    DBMS_OUTPUT.PUT_LINE(';');
  END;

  PROCEDURE emit_explain_section(
    p_schema IN VARCHAR2,
    p_child  IN NUMBER,
    p_orig   IN CLOB
  ) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE(
      '****************************************************************************************');
    DBMS_OUTPUT.PUT_LINE(
      '[3/3] EXPLAIN PLAN FOR paste (predicates)  sql_id=' || c_sqlid
      || '  child#=' || TO_CHAR(p_child)
      || '  schema=' || NVL(p_schema, '(null)'));
    DBMS_OUTPUT.PUT_LINE(
      '      Keep ? / :binds. ytop -f auto-runs this block for PLAN_DESCRIPTION (Param).');
    DBMS_OUTPUT.PUT_LINE(
      '****************************************************************************************');
    emit_explain_block(p_schema, p_child, p_orig);
  END;

BEGIN
  FOR c IN (
    SELECT s.child_number, s.parsing_schema_name, s.sql_fulltext
      FROM (
            SELECT child_number, parsing_schema_name, sql_fulltext,
                   ROW_NUMBER() OVER (
                     PARTITION BY child_number
                     ORDER BY last_load_time DESC NULLS LAST, child_address, address
                   ) AS rn
              FROM v$sql s
             WHERE s.sql_id = c_sqlid

           ) s
     WHERE s.rn = 1
     ORDER BY s.child_number
  ) LOOP
    ln_cnt := ln_cnt + 1;
    lvc_name := c.parsing_schema_name;
    IF DBMS_LOB.ISTEMPORARY(lvc_orig) = 1 THEN
      DBMS_LOB.FREETEMPORARY(lvc_orig);
    END IF;
    DBMS_LOB.CREATETEMPORARY(lvc_orig, TRUE);
    IF c.sql_fulltext IS NOT NULL THEN
      DBMS_LOB.APPEND(lvc_orig, c.sql_fulltext);
    END IF;
    emit_explain_section(lvc_name, c.child_number, lvc_orig);
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('-- children processed (EXPLAIN PLAN FOR): ' || TO_CHAR(ln_cnt));
END;
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

col owner              for   a15
col index_owner        for   a15
col table_owner        for   a15
col table_name         for   a25
col l_t                for   a5
col degree             for   a6
col part               for   a4
col LAST_ANALYZED      for   a19
col NUM_ROWS           for   a10
col blocks             for   a10
col EMPTY_BLOCKS       for   a5
col COLUMN_NAME        for   a15
col d_type             for   a20
col NUM_DISTINCT       for   a10
col N                  for   a1
col NUM_NULLS          for   a8
col sample_size        for   a10
col HISTOGRAM          for   a10
col segment_size       for   a15

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
SELECT b.owner,
       CASE WHEN EXISTS (
              SELECT 1 FROM tbl tt
               WHERE tt.owner = b.owner AND tt.table_name = b.segment_name
            )
            THEN '***' ELSE '' END || b.segment_name AS segment_name,
       b.segment_type,
       TRUNC(b.bytes / 1024 / 1024) || 'M' AS segment_size
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
SELECT a.owner,
       a.table_name,
       a.logging || '.' || a.temporary AS l_t,
       LTRIM(a.degree) AS degree,
       a.partitioned AS part,
       a.num_rows || '' AS num_rows,
       a.blocks || '' AS blocks,
       a.empty_blocks || '' AS empty_blocks,
       b.avg_space,
       b.avg_row_len,
       TRUNC((b.blocks * tp.block_size) / 1024 / 1024) AS block_size,
       TRUNC((b.avg_row_len * b.num_rows) / 1024 / 1024) AS avg_size,
       b.stale_stats,
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
SELECT a.owner,
       a.table_name,
       a.column_name,
       a.data_type || '(' || a.data_length || ')' AS d_type,
       b.num_distinct || '' AS num_distinct,
       a.nullable || '' AS n,
       b.num_nulls || '' AS num_nulls,
       b.density,
       b.num_buckets,
       b.avg_col_len,
       b.sample_size || '' AS sample_size,
       SUBSTR(b.histogram, 1, 5) AS histogram,
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

col index_name                 for a20
col PARTITION_NAME             for a20
col SUBPARTITION_NAME          for a20

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
SELECT owner,
       index_name,
       '' AS partition_name,
       '' AS subpartition_name,
       status
  FROM tt
 WHERE tt.partitioned = 'NO'
UNION ALL
SELECT p.index_owner,
       p.index_name,
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
SELECT p.index_owner,
       p.index_name,
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
SELECT a.table_owner,
       a.table_name,
       a.index_name,
          DECODE(a.uniqueness,  'UNIQUE', 'U',  'NONUNIQUE', 'N',  'O')
       || DECODE(a.compression, 'ENABLED', 'E',  'DISABLED', 'N',  'O')
       || DECODE(a.partitioned, 'YES', 'Y',  'NO', 'N',  'O')
       || DECODE(a.temporary,  'Y', 'Y',  'N', 'N',  'O')
       || DECODE(a.visibility, 'VISIBLE', 'V',  'INVISIBLE', 'I',  'O') AS ucptv,
       b.column_name,
       b.column_position,
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
SELECT a.owner,
       a.name AS index_name,
       b.partitioning_type AS part_type,
       b.subpartitioning_type AS subpart_type,
       b.partition_count AS part_count,
       b.partitioning_key_count AS key_count,
       b.subpartitioning_key_count AS subkey_cout,
       b.locality,
       a.column_name,
       a.column_position
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
SELECT a.owner,
       a.name AS table_name,
       b.partitioning_type AS part_type,
       b.subpartitioning_type AS subpart_type,
       b.partition_count AS part_count,
       b.partitioning_key_count AS key_count,
       b.subpartitioning_key_count AS subkey_cout,
       a.column_name,
       a.column_position
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

col tablespace_name         for a15
col HIGH_VALUE              for a25
col t_size                  for a10
col LAST_ANALYZED           for a19
col SPCNT                   for a5

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
SELECT p.table_name,
       p.partition_name,
       p.high_value,
       p.high_value_length,
       p.tablespace_name,
       p.num_rows || '' AS num_rows,
       p.blocks || '' AS blocks,
       ROUND(p.blocks * 8 / 1024, 2) || 'KB' AS t_size,
       p.empty_blocks || '' AS empty_blocks,
       TO_CHAR(p.last_analyzed, 'yyyy-mm-dd hh24:mi:ss') AS last_analyzed,
       p.avg_space || '' AS avg_space,
       SUBSTR(p.subpartition_count || '', 1, 5) AS spcnt
  FROM dba_tab_partitions p
  JOIN tbl x
    ON p.table_owner = x.owner
   AND p.table_name = x.table_name
 ORDER BY p.table_name, p.partition_position
/




