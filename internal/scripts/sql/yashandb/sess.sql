-- File Name: sess.sql
-- Purpose: YashanDB display session information
-- Created: 20260516  by  huangtingzhong

--
-- ytop / yasql:
--   ytop -t 10.10.10.130 -f print_table.sql
--
-- yasql treats $name in the script file as substitution variables. ytop (option A)
-- maps $ident to #ident in your  input; this script restores # via CHR(36).
-- You may type: select * from v$session where rownum <= 5

set serveroutput ON


DECLARE
  p_query     VARCHAR2(32767) := 'select * from gv$session where sid in (&sid_in)';
  c_id        INTEGER;
  col_cnt     INTEGER;
  desc_tab    DBMS_SQL.DESC_TAB;
  col_val     VARCHAR2(32767);
  row_num     INTEGER := 0;
  name_width  INTEGER := 0;
  status      INTEGER;
  v_sql       VARCHAR2(32767);
BEGIN
  DBMS_OUTPUT.ENABLE(1000000);

  v_sql := TRIM(BOTH ';' FROM TRIM(p_query));
  v_sql := REPLACE(v_sql, '#', CHR(36));
  IF v_sql IS NULL THEN
    RAISE_APPLICATION_ERROR(20001, 'query_sql is empty');
  END IF;

  c_id := DBMS_SQL.OPEN_CURSOR;
  DBMS_SQL.PARSE(c_id, v_sql, DBMS_SQL.NATIVE);
  DBMS_SQL.DESCRIBE_COLUMNS(c_id, col_cnt, desc_tab);

  FOR i IN 1 .. col_cnt LOOP
    IF LENGTH(desc_tab(i).col_name) > name_width THEN
      name_width := LENGTH(desc_tab(i).col_name);
    END IF;
  END LOOP;

  FOR i IN 1 .. col_cnt LOOP
    IF desc_tab(i).col_type = 113 THEN
      NULL;
    ELSE
      DBMS_SQL.DEFINE_COLUMN(c_id, i, col_val, 32767);
    END IF;
  END LOOP;

  status := DBMS_SQL.EXECUTE(c_id);

  WHILE DBMS_SQL.FETCH_ROWS(c_id) > 0 LOOP
    row_num := row_num + 1;
    DBMS_OUTPUT.PUT_LINE('=====row' || row_num || '=====');

    FOR i IN 1 .. col_cnt LOOP
      IF desc_tab(i).col_type = 113 THEN
        DBMS_OUTPUT.PUT_LINE(RPAD(desc_tab(i).col_name, name_width) || '=<BLOB>');
      ELSE
        DBMS_SQL.COLUMN_VALUE(c_id, i, col_val);
        DBMS_OUTPUT.PUT_LINE(RPAD(desc_tab(i).col_name, name_width) || '=' || col_val);
      END IF;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('');
  END LOOP;

  IF row_num = 0 THEN
    DBMS_OUTPUT.PUT_LINE('(no rows)');
  END IF;

  DBMS_SQL.CLOSE_CURSOR(c_id);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      IF DBMS_SQL.IS_OPEN(c_id) THEN
        DBMS_SQL.CLOSE_CURSOR(c_id);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
    DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
    RAISE;
END;
/
