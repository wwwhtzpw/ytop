-- File Name: stats_table_by_sqlid.sql
-- Purpose: Gather stats for all non-system tables referenced by a sql_id
-- Created: 20260801 by huangtingzhong
--
-- Params: &&sqlid (required),
--         &&percent (empty/0=AUTO; must be 0 or in [0.0001,1]),
--         &&method_opt (empty=FOR ALL COLUMNS SIZE AUTO),
--         &&cascade (default true), &&granularity (default AUTO),
--         &&degree (empty=NULL), &&block_sample (default false)
--
-- Objects: from gv$sql_plan (table + index->table); exclude DATABASE_MAINTAINED=Y owners.
-- sql_id lookup uses gv$sql (YAC multi-instance aware; not only local v$sql).
-- On gather error: continue next object and print failed DDL for manual replay.
-- Errors (RAISE_APPLICATION_ERROR, positive 304xx):
--   30401 invalid boolean; 30402 sqlid required; 30403 sqlid not in gv$sql;
--   30406 percent not number; 30407 percent out of range; 30408 degree invalid

SET SERVEROUTPUT ON


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Gather table stats by sql_id (skip system owners)                      |
PROMPT +------------------------------------------------------------------------+
PROMPT | Objects from gv$sql_plan; index objects resolve to base table          |
PROMPT | sql_id checked in gv$sql (all YAC instances), not only local v$sql     |
PROMPT | estimate_percent: 0 = AUTO, or [0.0001,1]. Example: 0.3 (=30 percent)   |
PROMPT | Gather failure does not stop; failed DDL is printed for manual run     |
PROMPT +------------------------------------------------------------------------+
PROMPT

PROMPT Enter sqlid (gv$sql.sql_id):
PROMPT Enter estimate percent (empty/0=AUTO, else 0.0001..1):
PROMPT Enter method_opt (empty=FOR ALL COLUMNS SIZE AUTO):
PROMPT Enter cascade (true/false, default true):
PROMPT Enter granularity (default AUTO):
PROMPT Enter degree (empty=NULL):
PROMPT Enter block_sample (true/false, default false):

DECLARE
  v_sqlid      VARCHAR2(64)  := NULLIF(TRIM('&&sqlid'), '');
  v_percent_s  VARCHAR2(64)  := TRIM('&&percent');
  v_method     VARCHAR2(4000) := TRIM('&&method_opt');
  v_cascade_s  VARCHAR2(32)  := LOWER(TRIM('&&cascade'));
  v_gran       VARCHAR2(64)  := UPPER(TRIM('&&granularity'));
  v_degree_s   VARCHAR2(64)  := TRIM('&&degree');
  v_bsample_s  VARCHAR2(32)  := LOWER(TRIM('&&block_sample'));

  v_percent    NUMBER;
  v_degree     NUMBER;
  v_cascade    BOOLEAN;
  v_bsample    BOOLEAN;
  v_exists     PLS_INTEGER;
  v_ok         PLS_INTEGER := 0;
  v_skip       PLS_INTEGER := 0;
  v_err        PLS_INTEGER := 0;
  v_found      BOOLEAN := FALSE;
  v_num_rows   NUMBER;
  v_sample     NUMBER;
  v_analyzed   VARCHAR2(32);
  v_start      DATE;
  v_elapsed_ms NUMBER;
  v_fail_ddl   CLOB := EMPTY_CLOB();
  v_inst_list  VARCHAR2(4000);

  PROCEDURE log_line(p_msg VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSDATE, 'yyyy-mm-dd hh24:mi:ss') || ' ' || p_msg);
  END log_line;

  FUNCTION parse_bool(p_raw VARCHAR2, p_default BOOLEAN) RETURN BOOLEAN IS
    v VARCHAR2(32) := LOWER(TRIM(p_raw));
  BEGIN
    IF v IS NULL OR v = '' THEN
      RETURN p_default;
    ELSIF v IN ('true', 't', 'yes', 'y', '1') THEN
      RETURN TRUE;
    ELSIF v IN ('false', 'f', 'no', 'n', '0') THEN
      RETURN FALSE;
    ELSE
      RAISE_APPLICATION_ERROR(30401, 'Invalid boolean value: ' || p_raw || ' (use true/false)');
    END IF;
  END parse_bool;

  FUNCTION bool_text(p_val BOOLEAN) RETURN VARCHAR2 IS
  BEGIN
    IF p_val THEN
      RETURN 'TRUE';
    END IF;
    RETURN 'FALSE';
  END bool_text;

  FUNCTION quote_literal(p_val VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_val IS NULL THEN
      RETURN 'NULL';
    END IF;
    RETURN '''' || REPLACE(p_val, '''', '''''') || '''';
  END quote_literal;

  FUNCTION gather_ddl(p_owner VARCHAR2, p_table VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN
      'BEGIN' || CHR(10) ||
      '  DBMS_STATS.GATHER_TABLE_STATS(' || CHR(10) ||
      '    ownname          => ' || quote_literal(p_owner) || ',' || CHR(10) ||
      '    tabname          => ' || quote_literal(p_table) || ',' || CHR(10) ||
      '    partname         => NULL,' || CHR(10) ||
      '    estimate_percent => ' || TO_CHAR(v_percent) || ',' || CHR(10) ||
      '    block_sample     => ' || bool_text(v_bsample) || ',' || CHR(10) ||
      '    method_opt       => ' || quote_literal(v_method) || ',' || CHR(10) ||
      '    degree           => ' || NVL(TO_CHAR(v_degree), 'NULL') || ',' || CHR(10) ||
      '    granularity      => ' || quote_literal(v_gran) || ',' || CHR(10) ||
      '    cascade          => ' || bool_text(v_cascade) || CHR(10) ||
      '  );' || CHR(10) ||
      'END;' || CHR(10) ||
      '/';
  END gather_ddl;

  PROCEDURE print_ddl(p_title VARCHAR2, p_owner VARCHAR2, p_table VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(p_title);
    DBMS_OUTPUT.PUT_LINE(gather_ddl(p_owner, p_table));
  END print_ddl;

  PROCEDURE append_fail_ddl(p_owner VARCHAR2, p_table VARCHAR2, p_err VARCHAR2) IS
  BEGIN
    v_fail_ddl := v_fail_ddl
      || '-- FAIL ' || p_owner || '.' || p_table || ' : ' || p_err || CHR(10)
      || gather_ddl(p_owner, p_table) || CHR(10) || CHR(10);
  END append_fail_ddl;

  PROCEDURE gather_one(p_owner VARCHAR2, p_table VARCHAR2) IS
  BEGIN
    log_line('GATHER start ' || p_owner || '.' || p_table);
    v_start := SYSDATE;
    DBMS_STATS.GATHER_TABLE_STATS(
      ownname          => p_owner,
      tabname          => p_table,
      partname         => NULL,
      estimate_percent => v_percent,
      block_sample     => v_bsample,
      method_opt       => v_method,
      degree           => v_degree,
      granularity      => v_gran,
      cascade          => v_cascade
    );
    v_elapsed_ms := (SYSDATE - v_start) * 86400 * 1000;

    BEGIN
      SELECT num_rows,
             sample_size,
             TO_CHAR(last_analyzed, 'yyyy-mm-dd hh24:mi:ss')
        INTO v_num_rows, v_sample, v_analyzed
        FROM dba_tab_statistics
       WHERE owner = p_owner
         AND table_name = p_table
         AND partition_name IS NULL
         AND ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_num_rows := NULL;
        v_sample := NULL;
        v_analyzed := NULL;
    END;

    v_ok := v_ok + 1;
    log_line('OK   ' || p_owner || '.' || p_table
             || ' elapsed_ms=' || TO_CHAR(ROUND(v_elapsed_ms))
             || ' num_rows=' || NVL(TO_CHAR(v_num_rows), 'NULL')
             || ' sample_size=' || NVL(TO_CHAR(v_sample), 'NULL')
             || ' last_analyzed=' || NVL(v_analyzed, 'NULL'));
    print_ddl('-- gather DDL (ok)', p_owner, p_table);
  EXCEPTION
    WHEN OTHERS THEN
      v_err := v_err + 1;
      log_line('FAIL ' || p_owner || '.' || p_table || ' : ' || SQLERRM);
      print_ddl('-- failed DDL (manual replay)', p_owner, p_table);
      append_fail_ddl(p_owner, p_table, SQLERRM);
  END gather_one;
BEGIN
  IF v_sqlid IS NULL THEN
    RAISE_APPLICATION_ERROR(30402, 'sqlid is required');
  END IF;

  -- Pre-check: sql_id must exist in gv$sql (covers YAC multi-node; local v$sql alone is not enough)
  SELECT COUNT(*) INTO v_exists FROM gv$sql WHERE sql_id = v_sqlid;
  IF v_exists = 0 THEN
    RAISE_APPLICATION_ERROR(
      30403,
      'sql_id not found in gv$sql (all instances): ' || v_sqlid
      || ' (cursor may have aged out; re-execute the SQL then retry)'
    );
  END IF;

  v_inst_list := NULL;
  FOR i IN (
    SELECT DISTINCT inst_id
      FROM gv$sql
     WHERE sql_id = v_sqlid
     ORDER BY inst_id
  ) LOOP
    IF v_inst_list IS NULL THEN
      v_inst_list := TO_CHAR(i.inst_id);
    ELSE
      v_inst_list := v_inst_list || ',' || TO_CHAR(i.inst_id);
    END IF;
  END LOOP;

  IF v_percent_s IS NULL OR v_percent_s = '' THEN
    v_percent := 0;
  ELSE
    BEGIN
      v_percent := TO_NUMBER(v_percent_s);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(30406, 'estimate_percent must be a number: ' || v_percent_s);
    END;
    IF v_percent <> 0 AND (v_percent < 0.0001 OR v_percent > 1) THEN
      RAISE_APPLICATION_ERROR(
        30407,
        'estimate_percent must be 0 (AUTO) or in [0.0001,1]; got ' || v_percent_s
        || ' (YashanDB uses fraction, e.g. 0.3 not 30)'
      );
    END IF;
  END IF;

  IF v_method IS NULL OR v_method = '' THEN
    v_method := 'FOR ALL COLUMNS SIZE AUTO';
  ELSE
    v_method := UPPER(v_method);
  END IF;

  IF v_gran IS NULL OR v_gran = '' THEN
    v_gran := 'AUTO';
  END IF;

  IF v_degree_s IS NULL OR v_degree_s = '' THEN
    v_degree := NULL;
  ELSE
    BEGIN
      v_degree := TO_NUMBER(v_degree_s);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(30408, 'degree must be a number or empty: ' || v_degree_s);
    END;
  END IF;

  v_cascade := parse_bool(v_cascade_s, TRUE);
  v_bsample := parse_bool(v_bsample_s, FALSE);

  log_line('INFO sqlid=' || v_sqlid || ' found_on_inst_id=' || NVL(v_inst_list, '?'));
  log_line('INFO estimate_percent=' || TO_CHAR(v_percent)
           || ' method_opt=' || v_method
           || ' cascade=' || bool_text(v_cascade)
           || ' granularity=' || v_gran
           || ' degree=' || NVL(TO_CHAR(v_degree), 'NULL')
           || ' block_sample=' || bool_text(v_bsample));

  -- list skipped system-owned objects for visibility (all instances via gv$sql_plan)
  FOR s IN (
    SELECT DISTINCT owner, table_name
      FROM (
            SELECT i.table_owner AS owner, i.table_name
              FROM gv$sql_plan p, dba_indexes i
             WHERE p.sql_id = v_sqlid
               AND p.object_name IS NOT NULL
               AND i.owner = p.object_owner
               AND i.index_name = p.object_name
            UNION
            SELECT p.object_owner AS owner, p.object_name AS table_name
              FROM gv$sql_plan p, dba_tables t
             WHERE p.sql_id = v_sqlid
               AND p.object_name IS NOT NULL
               AND t.owner = p.object_owner
               AND t.table_name = p.object_name
           ) x
         , dba_users u
     WHERE u.username = x.owner
       AND NVL(u.database_maintained, 'N') = 'Y'
     ORDER BY 1, 2
  ) LOOP
    v_skip := v_skip + 1;
    log_line('SKIP system owner ' || s.owner || '.' || s.table_name
             || ' (DATABASE_MAINTAINED=Y)');
  END LOOP;

  FOR r IN (
    SELECT DISTINCT owner, table_name
      FROM (
            SELECT i.table_owner AS owner, i.table_name
              FROM gv$sql_plan p, dba_indexes i
             WHERE p.sql_id = v_sqlid
               AND p.object_name IS NOT NULL
               AND i.owner = p.object_owner
               AND i.index_name = p.object_name
            UNION
            SELECT p.object_owner AS owner, p.object_name AS table_name
              FROM gv$sql_plan p, dba_tables t
             WHERE p.sql_id = v_sqlid
               AND p.object_name IS NOT NULL
               AND t.owner = p.object_owner
               AND t.table_name = p.object_name
           ) x
         , dba_users u
     WHERE u.username = x.owner
       AND NVL(u.database_maintained, 'N') = 'N'
     ORDER BY 1, 2
  ) LOOP
    v_found := TRUE;
    gather_one(r.owner, r.table_name);
  END LOOP;

  IF NOT v_found THEN
    log_line('WARN no non-system table found for sql_id=' || v_sqlid);
  END IF;

  log_line('DONE ok=' || v_ok || ' skipped_system=' || v_skip || ' failed=' || v_err);

  IF v_err > 0 THEN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('-- ========== FAILED DDL SUMMARY (manual replay) ==========');
    DBMS_OUTPUT.PUT_LINE(v_fail_ddl);
    DBMS_OUTPUT.PUT_LINE('-- ========== END FAILED DDL SUMMARY ==========');
  END IF;
END;
/
