-- File Name: stats_delete_column_stat.sql
-- Purpose: Delete column statistics (ALL: column stats + histogram)
-- Created: 20260801 by huangtingzhong
--
-- Flow: list columns; if column_name set, check table/column then delete ALL then list again
-- Note: ytop prompts all vars before run; leave column_name empty to list only
-- Note: YashanDB uses type=>'ALL' (Oracle script omits type / uses cascade_parts)
-- Errors (RAISE_APPLICATION_ERROR, positive 305xx):
--   30503 table not found
--   30504 column not found

SET SERVEROUTPUT ON


col t_t_n        for a25
col column_id    for a6
col column_name  for a20
col d_type       for a18
col nullable     for a7
col num_nulls    for a10
col num_distinct for a12
col num_buckets  for a10
col density      for a12
col last_analyzed for a19
col sample_size  for a10
col histogram    for a10

ACCEPT owner PROMPT 'Enter table owner (e.g. HTZ): '
ACCEPT name PROMPT 'Enter table name (e.g. PART): '
ACCEPT column_name PROMPT 'Enter column_name to delete stats (empty=list only): '

SELECT tb.table_name AS t_t_n,
       TO_CHAR(tb.column_id) AS column_id,
       tb.column_name,
       tb.data_type || '(' || TO_CHAR(tb.data_length) || ')' AS d_type,
       tb.nullable,
       TO_CHAR(tc.num_nulls) AS num_nulls,
       TO_CHAR(tc.num_distinct) AS num_distinct,
       TO_CHAR(tc.num_buckets) AS num_buckets,
       TO_CHAR(tc.density) AS density,
       TO_CHAR(tc.last_analyzed, 'yyyy-mm-dd hh24:mi:ss') AS last_analyzed,
       TO_CHAR(tc.sample_size) AS sample_size,
       tc.histogram
  FROM dba_tab_cols tb, dba_tab_col_statistics tc
 WHERE tb.owner = UPPER(TRIM('&&owner'))
   AND tb.table_name = UPPER(TRIM('&&name'))
   AND tc.owner(+) = tb.owner
   AND tc.table_name(+) = tb.table_name
   AND tc.column_name(+) = tb.column_name
 ORDER BY tb.column_id;

DECLARE
  v_owner  VARCHAR2(128) := UPPER(TRIM('&&owner'));
  v_table  VARCHAR2(128) := UPPER(TRIM('&&name'));
  v_col    VARCHAR2(128) := NULLIF(UPPER(TRIM('&&column_name')), '');
  v_exists PLS_INTEGER;
BEGIN
  IF v_col IS NULL THEN
    RETURN;
  END IF;

  SELECT COUNT(*)
    INTO v_exists
    FROM dba_tables
   WHERE owner = v_owner
     AND table_name = v_table;
  IF v_exists = 0 THEN
    RAISE_APPLICATION_ERROR(30503, 'table not found: ' || v_owner || '.' || v_table);
  END IF;

  SELECT COUNT(*)
    INTO v_exists
    FROM dba_tab_cols
   WHERE owner = v_owner
     AND table_name = v_table
     AND column_name = v_col;
  IF v_exists = 0 THEN
    RAISE_APPLICATION_ERROR(
      30504,
      'column not found: ' || v_owner || '.' || v_table || '.' || v_col
    );
  END IF;

  DBMS_STATS.DELETE_COLUMN_STATS(
    ownname       => v_owner,
    tabname       => v_table,
    colname       => v_col,
    type          => 'ALL',
    cascade_parts => TRUE
  );
END;
/

SELECT tb.table_name AS t_t_n,
       TO_CHAR(tb.column_id) AS column_id,
       tb.column_name,
       tb.data_type || '(' || TO_CHAR(tb.data_length) || ')' AS d_type,
       tb.nullable,
       TO_CHAR(tc.num_nulls) AS num_nulls,
       TO_CHAR(tc.num_distinct) AS num_distinct,
       TO_CHAR(tc.num_buckets) AS num_buckets,
       TO_CHAR(tc.density) AS density,
       TO_CHAR(tc.last_analyzed, 'yyyy-mm-dd hh24:mi:ss') AS last_analyzed,
       TO_CHAR(tc.sample_size) AS sample_size,
       tc.histogram
  FROM dba_tab_cols tb, dba_tab_col_statistics tc
 WHERE tb.owner = UPPER(TRIM('&&owner'))
   AND tb.table_name = UPPER(TRIM('&&name'))
   AND tc.owner(+) = tb.owner
   AND tc.table_name(+) = tb.table_name
   AND tc.column_name(+) = tb.column_name
   AND NULLIF(UPPER(TRIM('&&column_name')), '') IS NOT NULL
 ORDER BY tb.column_id;
