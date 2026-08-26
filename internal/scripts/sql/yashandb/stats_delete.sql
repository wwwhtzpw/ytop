-- File Name: stats_delete.sql
-- Purpose: Delete table, partition, column statistics
-- Created: 20260630  by  huangtingzhong
--
-- Params: &&owner (required, non-system user), &&tablename (empty=all tables),
--         &&partname (empty=whole table and all partitions),
--         &&colname (empty=all columns),
--         &dryrun (Enter=1 print only, 0=execute)

SET SERVEROUTPUT ON
SET VERIFY OFF
SET FEEDBACK OFF


PROMPT Enter dryrun (Enter=1 print only, 0=execute):
PROMPT Enter owner (required, non-system user):
PROMPT Enter table name (empty=all tables in owner):
PROMPT Enter partition name (empty=whole table and all partitions):
PROMPT Enter column name (empty=all columns):

DECLARE
  v_owner   VARCHAR2(128) := NULLIF(UPPER(TRIM('&&owner')), '');
  v_table   VARCHAR2(128) := NULLIF(UPPER(TRIM('&&tablename')), '');
  v_part    VARCHAR2(128) := NULLIF(UPPER(TRIM('&&partname')), '');
  v_col     VARCHAR2(128) := NULLIF(UPPER(TRIM('&&colname')), '');
  v_dryrun  NUMBER       := NVL(TO_NUMBER(NULLIF(TRIM('&&dryrun'), '')), 1);
  v_ok      PLS_INTEGER := 0;
  v_skip    PLS_INTEGER := 0;
  v_err     PLS_INTEGER := 0;
  v_found   BOOLEAN := FALSE;
  v_exists  PLS_INTEGER;
  v_maint   VARCHAR2(1);

  PROCEDURE log_action(p_msg VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSDATE, 'yyyy-mm-dd hh24:mi:ss') || ' ' || p_msg);
  END log_action;

  FUNCTION quote_literal(p_val VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_val IS NULL THEN
      RETURN 'NULL';
    END IF;
    RETURN '''' || REPLACE(p_val, '''', '''''') || '''';
  END quote_literal;

  PROCEDURE print_delete_column_stats(
    p_table   VARCHAR2,
    p_part    VARCHAR2,
    p_col     VARCHAR2
  ) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('BEGIN');
    DBMS_OUTPUT.PUT_LINE('  DBMS_STATS.DELETE_COLUMN_STATS(');
    DBMS_OUTPUT.PUT_LINE('    ownname       => ' || quote_literal(v_owner) || ',');
    DBMS_OUTPUT.PUT_LINE('    tabname       => ' || quote_literal(p_table) || ',');
    DBMS_OUTPUT.PUT_LINE('    colname       => ' || quote_literal(p_col) || ',');
    DBMS_OUTPUT.PUT_LINE('    partname      => ' || quote_literal(p_part) || ',');
    DBMS_OUTPUT.PUT_LINE('    type          => ''ALL'',');
    DBMS_OUTPUT.PUT_LINE('    cascade_parts => TRUE,');
    DBMS_OUTPUT.PUT_LINE('    force         => FALSE');
    DBMS_OUTPUT.PUT_LINE('  );');
    DBMS_OUTPUT.PUT_LINE('END;');
    DBMS_OUTPUT.PUT_LINE('/');
  END print_delete_column_stats;

  PROCEDURE print_delete_table_stats(
    p_table VARCHAR2,
    p_part  VARCHAR2
  ) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('BEGIN');
    DBMS_OUTPUT.PUT_LINE('  DBMS_STATS.DELETE_TABLE_STATS(');
    DBMS_OUTPUT.PUT_LINE('    ownname         => ' || quote_literal(v_owner) || ',');
    DBMS_OUTPUT.PUT_LINE('    tabname         => ' || quote_literal(p_table) || ',');
    DBMS_OUTPUT.PUT_LINE('    partname        => ' || quote_literal(p_part) || ',');
    DBMS_OUTPUT.PUT_LINE('    cascade_parts   => TRUE,');
    DBMS_OUTPUT.PUT_LINE('    cascade_columns => TRUE,');
    DBMS_OUTPUT.PUT_LINE('    cascade_indexes => TRUE,');
    DBMS_OUTPUT.PUT_LINE('    force           => FALSE');
    DBMS_OUTPUT.PUT_LINE('  );');
    DBMS_OUTPUT.PUT_LINE('END;');
    DBMS_OUTPUT.PUT_LINE('/');
  END print_delete_table_stats;

  PROCEDURE delete_stats_for_table(p_table VARCHAR2) IS
    v_scope VARCHAR2(512);
  BEGIN
    IF v_col IS NOT NULL THEN
      SELECT COUNT(*)
        INTO v_exists
        FROM dba_tab_cols
       WHERE owner = v_owner
         AND table_name = p_table
         AND column_name = v_col;

      IF v_exists = 0 THEN
        v_skip := v_skip + 1;
        log_action('SKIP ' || v_owner || '.' || p_table || ' column ' || v_col || ' not found');
        RETURN;
      END IF;

      IF v_part IS NOT NULL THEN
        SELECT COUNT(*)
          INTO v_exists
          FROM dba_tab_partitions
         WHERE table_owner = v_owner
           AND table_name = p_table
           AND partition_name = v_part;

        IF v_exists = 0 THEN
          v_skip := v_skip + 1;
          log_action('SKIP ' || v_owner || '.' || p_table || ' partition ' || v_part || ' not found');
          RETURN;
        END IF;

        v_scope := v_owner || '.' || p_table || '(' || v_part || ').' || v_col;
        IF NVL(v_dryrun, 1) = 0 THEN
          DBMS_STATS.DELETE_COLUMN_STATS(
            ownname       => v_owner,
            tabname       => p_table,
            colname       => v_col,
            partname      => v_part,
            type          => 'ALL',
            cascade_parts => TRUE,
            force         => FALSE
          );
        ELSE
          log_action('DRYRUN ' || v_scope);
          print_delete_column_stats(p_table, v_part, v_col);
        END IF;
      ELSE
        v_scope := v_owner || '.' || p_table || '.' || v_col;
        IF NVL(v_dryrun, 1) = 0 THEN
          DBMS_STATS.DELETE_COLUMN_STATS(
            ownname       => v_owner,
            tabname       => p_table,
            colname       => v_col,
            partname      => NULL,
            type          => 'ALL',
            cascade_parts => TRUE,
            force         => FALSE
          );
        ELSE
          log_action('DRYRUN ' || v_scope);
          print_delete_column_stats(p_table, NULL, v_col);
        END IF;
      END IF;
    ELSIF v_part IS NOT NULL THEN
      SELECT COUNT(*)
        INTO v_exists
        FROM dba_tab_partitions
       WHERE table_owner = v_owner
         AND table_name = p_table
         AND partition_name = v_part;

      IF v_exists = 0 THEN
        v_skip := v_skip + 1;
        log_action('SKIP ' || v_owner || '.' || p_table || ' partition ' || v_part || ' not found');
        RETURN;
      END IF;

      v_scope := v_owner || '.' || p_table || '(' || v_part || ')';
      IF NVL(v_dryrun, 1) = 0 THEN
        DBMS_STATS.DELETE_TABLE_STATS(
          ownname         => v_owner,
          tabname         => p_table,
          partname        => v_part,
          cascade_parts   => TRUE,
          cascade_columns => TRUE,
          cascade_indexes => TRUE,
          force           => FALSE
        );
      ELSE
        log_action('DRYRUN ' || v_scope);
        print_delete_table_stats(p_table, v_part);
      END IF;
    ELSE
      v_scope := v_owner || '.' || p_table;
      IF NVL(v_dryrun, 1) = 0 THEN
        DBMS_STATS.DELETE_TABLE_STATS(
          ownname         => v_owner,
          tabname         => p_table,
          partname        => NULL,
          cascade_parts   => TRUE,
          cascade_columns => TRUE,
          cascade_indexes => TRUE,
          force           => FALSE
        );
      ELSE
        log_action('DRYRUN ' || v_scope);
        print_delete_table_stats(p_table, NULL);
      END IF;
    END IF;

    v_ok := v_ok + 1;
    IF NVL(v_dryrun, 1) = 0 THEN
      log_action('OK   deleted stats: ' || v_scope);
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_err := v_err + 1;
      log_action('ERR  ' || v_owner || '.' || p_table || ': ' || SQLERRM);
  END delete_stats_for_table;

BEGIN
  IF v_owner IS NULL THEN
    log_action('ERR  owner is required (system users are not allowed)');
    RETURN;
  END IF;

  BEGIN
    SELECT database_maintained
      INTO v_maint
      FROM dba_users
     WHERE username = v_owner;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      log_action('ERR  owner not found: ' || v_owner);
      RETURN;
  END;

  IF NVL(v_maint, 'N') = 'Y' THEN
    log_action('ERR  system owner not allowed: ' || v_owner ||
               ' (DATABASE_MAINTAINED=Y)');
    RETURN;
  END IF;

  log_action('INFO dryrun=' || NVL(v_dryrun, 1) ||
             CASE WHEN NVL(v_dryrun, 1) = 0 THEN ' (execute)' ELSE ' (print only)' END ||
             ', owner=' || v_owner ||
             ', table=' || NVL(v_table, '<ALL>') ||
             ', partition=' || NVL(v_part, '<ALL>') ||
             ', column=' || NVL(v_col, '<ALL>'));

  FOR rec IN (
    SELECT table_name
      FROM dba_tables
     WHERE owner = v_owner
       AND (v_table IS NULL OR table_name = v_table)
     ORDER BY table_name
  ) LOOP
    v_found := TRUE;
    delete_stats_for_table(rec.table_name);
  END LOOP;

  IF NOT v_found THEN
    log_action('WARN no matching table: ' || v_owner || '.' || NVL(v_table, '*'));
  END IF;

  log_action('DONE ' || CASE WHEN NVL(v_dryrun, 1) = 0 THEN 'deleted=' ELSE 'planned=' END ||
             v_ok || ', skipped=' || v_skip || ', errors=' || v_err);
END;
/
