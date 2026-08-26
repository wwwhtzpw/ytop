-- File Name: stats_table.sql
-- Purpose: Gather table statistics via DBMS_STATS.GATHER_TABLE_STATS
-- Created: 20260801 by huangtingzhong
--
-- Params: &&owner (required), &&tablename (required),
--         &&partname (empty=whole table),
--         &&percent (empty/0=AUTO; must be 0 or in [0.0001,1]),
--         &&method_opt (empty=FOR ALL COLUMNS SIZE AUTO),
--         &&cascade (default true), &&granularity (default AUTO),
--         &&degree (empty=NULL), &&block_sample (default false)
--
-- Note: YashanDB estimate_percent is a fraction in [0.0001,1] or 0=AUTO.
--       Oracle-style percent values such as 30 are rejected (use 0.3).
-- Errors (RAISE_APPLICATION_ERROR, positive 303xx):
--   30301 invalid boolean; 30302 owner required; 30303 table required;
--   30304 table not found; 30305 partition not found;
--   30306 percent not number; 30307 percent out of range; 30308 degree invalid

SET SERVEROUTPUT ON


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | DBMS_STATS.GATHER_TABLE_STATS (YashanDB)                               |
PROMPT +------------------------------------------------------------------------+
PROMPT | estimate_percent: 0 = AUTO, or [0.0001,1]. Example: 0.3 (=30 percent)   |
PROMPT | method_opt default: FOR ALL COLUMNS SIZE AUTO                          |
PROMPT | method_opt examples:                                                   |
PROMPT |   FOR ALL COLUMNS SIZE AUTO | SIZE 1 | SIZE REPEAT                     |
PROMPT |   FOR ALL INDEXED COLUMNS SIZE AUTO                                    |
PROMPT |   FOR COLUMNS (COL1) SIZE 10     -- note: column list needs parentheses|
PROMPT | histogram SIZE integer range: [1, 2048]                                |
PROMPT | granularity: AUTO | ALL | GLOBAL | GLOBAL AND PARTITION | PARTITION    |
PROMPT +------------------------------------------------------------------------+
PROMPT

PROMPT Enter owner (required, e.g. SCOTT):
PROMPT Enter table name (required, e.g. DEPT):
PROMPT Enter partition name (empty=whole table):
PROMPT Enter estimate percent (empty/0=AUTO, else 0.0001..1):
PROMPT Enter method_opt (empty=FOR ALL COLUMNS SIZE AUTO):
PROMPT Enter cascade (true/false, default true):
PROMPT Enter granularity (default AUTO):
PROMPT Enter degree (empty=NULL):
PROMPT Enter block_sample (true/false, default false):

DECLARE
  v_owner      VARCHAR2(128) := NULLIF(UPPER(TRIM('&&owner')), '');
  v_table      VARCHAR2(128) := NULLIF(UPPER(TRIM('&&tablename')), '');
  v_part       VARCHAR2(128) := NULLIF(UPPER(TRIM('&&partname')), '');
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
  v_num_rows   NUMBER;
  v_sample     NUMBER;
  v_analyzed   VARCHAR2(32);
  v_start      DATE;
  v_elapsed_ms NUMBER;

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
      RAISE_APPLICATION_ERROR(30301, 'Invalid boolean value: ' || p_raw || ' (use true/false)');
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

  PROCEDURE print_gather_ddl IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('-- gather DDL (replay)');
    DBMS_OUTPUT.PUT_LINE('BEGIN');
    DBMS_OUTPUT.PUT_LINE('  DBMS_STATS.GATHER_TABLE_STATS(');
    DBMS_OUTPUT.PUT_LINE('    ownname          => ' || quote_literal(v_owner) || ',');
    DBMS_OUTPUT.PUT_LINE('    tabname          => ' || quote_literal(v_table) || ',');
    DBMS_OUTPUT.PUT_LINE('    partname         => ' || quote_literal(v_part) || ',');
    DBMS_OUTPUT.PUT_LINE('    estimate_percent => ' || TO_CHAR(v_percent) || ',');
    DBMS_OUTPUT.PUT_LINE('    block_sample     => ' || bool_text(v_bsample) || ',');
    DBMS_OUTPUT.PUT_LINE('    method_opt       => ' || quote_literal(v_method) || ',');
    DBMS_OUTPUT.PUT_LINE('    degree           => ' || NVL(TO_CHAR(v_degree), 'NULL') || ',');
    DBMS_OUTPUT.PUT_LINE('    granularity      => ' || quote_literal(v_gran) || ',');
    DBMS_OUTPUT.PUT_LINE('    cascade          => ' || bool_text(v_cascade));
    DBMS_OUTPUT.PUT_LINE('  );');
    DBMS_OUTPUT.PUT_LINE('END;');
    DBMS_OUTPUT.PUT_LINE('/');
  END print_gather_ddl;
BEGIN
  IF v_owner IS NULL THEN
    RAISE_APPLICATION_ERROR(30302, 'owner is required');
  END IF;
  IF v_table IS NULL THEN
    RAISE_APPLICATION_ERROR(30303, 'table name is required');
  END IF;

  SELECT COUNT(*)
    INTO v_exists
    FROM dba_tables
   WHERE owner = v_owner
     AND table_name = v_table;
  IF v_exists = 0 THEN
    RAISE_APPLICATION_ERROR(30304, 'table not found: ' || v_owner || '.' || v_table);
  END IF;

  IF v_part IS NOT NULL THEN
    SELECT COUNT(*)
      INTO v_exists
      FROM dba_tab_partitions
     WHERE table_owner = v_owner
       AND table_name = v_table
       AND partition_name = v_part;
    IF v_exists = 0 THEN
      RAISE_APPLICATION_ERROR(30305, 'partition not found: ' || v_owner || '.' || v_table || '(' || v_part || ')');
    END IF;
  END IF;

  IF v_percent_s IS NULL OR v_percent_s = '' THEN
    v_percent := 0;
  ELSE
    BEGIN
      v_percent := TO_NUMBER(v_percent_s);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(30306, 'estimate_percent must be a number: ' || v_percent_s);
    END;
    IF v_percent <> 0 AND (v_percent < 0.0001 OR v_percent > 1) THEN
      RAISE_APPLICATION_ERROR(
        30307,
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
        RAISE_APPLICATION_ERROR(30308, 'degree must be a number or empty: ' || v_degree_s);
    END;
  END IF;

  v_cascade := parse_bool(v_cascade_s, TRUE);
  v_bsample := parse_bool(v_bsample_s, FALSE);

  log_line('GATHER_TABLE_STATS start');
  log_line('  ownname=' || v_owner);
  log_line('  tabname=' || v_table);
  log_line('  partname=' || NVL(v_part, 'NULL'));
  log_line('  estimate_percent=' || TO_CHAR(v_percent));
  log_line('  method_opt=' || v_method);
  log_line('  cascade=' || bool_text(v_cascade));
  log_line('  granularity=' || v_gran);
  log_line('  degree=' || NVL(TO_CHAR(v_degree), 'NULL'));
  log_line('  block_sample=' || bool_text(v_bsample));

  v_start := SYSDATE;
  DBMS_STATS.GATHER_TABLE_STATS(
    ownname          => v_owner,
    tabname          => v_table,
    partname         => v_part,
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
     WHERE owner = v_owner
       AND table_name = v_table
       AND ((v_part IS NULL AND partition_name IS NULL)
            OR partition_name = v_part)
       AND ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      v_num_rows := NULL;
      v_sample := NULL;
      v_analyzed := NULL;
  END;

  log_line('GATHER_TABLE_STATS done elapsed_ms=' || TO_CHAR(ROUND(v_elapsed_ms)));
  log_line('  num_rows=' || NVL(TO_CHAR(v_num_rows), 'NULL')
           || ' sample_size=' || NVL(TO_CHAR(v_sample), 'NULL')
           || ' last_analyzed=' || NVL(v_analyzed, 'NULL'));
  print_gather_ddl;
END;
/
