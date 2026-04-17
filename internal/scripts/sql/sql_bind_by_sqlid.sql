-- =============================================================================
-- Purpose: Expand SQL text by replacing '?' placeholders with captured bind values
--          from V$SQL_BIND_CAPTURE, ordered by POSITION.
-- Notes:
--   - YashanDB bind placeholder is '?', so replacement is position-based.
--   - If V$SQL has no rows for the sql_id, print message and RETURN (no error).
--   - DATE/TIMESTAMP values are wrapped with to_date/to_timestamp (simple form).
-- Usage:
--   1) Edit c_sqlid below, then run with ysql -f this_file
-- =============================================================================

SET SERVEROUTPUT ON 

DECLARE
  c_sqlid           CONSTANT VARCHAR2(64) := '&&sqlid';

  lvc_sql_text      VARCHAR2(32000);
  lvc_orig_sql_text VARCHAR2(32000);
  ln_child          NUMBER := 10000;
  lvc_repl          VARCHAR2(2000);
  lvc_name          VARCHAR2(30);

  ln_bind_count     NUMBER := 0;
  ln_sql_cnt        NUMBER := 0;
  ln_qpos           NUMBER;

  CURSOR c1 IS
    SELECT child_number,
           name,
           position,
           datatype_string,
           value_string,
           sql_id
      FROM v$sql_bind_capture
     WHERE sql_id = c_sqlid
     ORDER BY child_number, position;
BEGIN
  SELECT COUNT(*)
    INTO ln_sql_cnt
    FROM v$sql
   WHERE sql_id = c_sqlid;

  IF ln_sql_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No SQL found in V$SQL for sql_id=' || c_sqlid);
    RETURN;
  END IF;

  SELECT sql_fulltext
    INTO lvc_orig_sql_text
    FROM v$sql
   WHERE sql_id = c_sqlid
     AND ROWNUM = 1;

  SELECT parsing_schema_name
    INTO lvc_name
    FROM v$sql
   WHERE sql_id = c_sqlid
     AND ROWNUM = 1;


  IF REGEXP_LIKE(lvc_orig_sql_text, '^\s*(UPDATE|DELETE)\b', 'i') THEN
    DBMS_OUTPUT.PUT_LINE('Schema: ' || lvc_name);
    DBMS_OUTPUT.PUT_LINE(lvc_orig_sql_text);
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
    RETURN;
  END IF;

  SELECT COUNT(*)
    INTO ln_bind_count
    FROM v$sql_bind_capture
   WHERE sql_id = c_sqlid;

  IF ln_bind_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Schema: ' || lvc_name);
    DBMS_OUTPUT.PUT_LINE(lvc_orig_sql_text);
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
    RETURN;
  END IF;

  FOR r1 IN c1 LOOP
    IF (r1.child_number <> ln_child) THEN
      IF ln_child <> 10000 THEN
        DBMS_OUTPUT.PUT_LINE(lvc_name);
        DBMS_OUTPUT.PUT_LINE(lvc_sql_text);
        DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
      END IF;

      ln_child     := r1.child_number;
      lvc_sql_text := lvc_orig_sql_text;
    END IF;

    BEGIN
      SELECT parsing_schema_name
        INTO lvc_name
        FROM v$sql
       WHERE sql_id = r1.sql_id
         AND child_number = r1.child_number;
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;

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

    ln_qpos := INSTR(lvc_sql_text, '?');
    IF ln_qpos = 0 THEN
      DBMS_OUTPUT.PUT_LINE(
        'ERROR: no remaining ''?'' placeholders while replacing binds. ' ||
        'bind position=' || r1.position
      );
      RETURN;
    END IF;

    lvc_sql_text :=
      SUBSTR(lvc_sql_text, 1, ln_qpos - 1) ||
      lvc_repl ||
      SUBSTR(lvc_sql_text, ln_qpos + 1);
  END LOOP;

  DBMS_OUTPUT.PUT_LINE(lvc_name);
  DBMS_OUTPUT.PUT_LINE(lvc_sql_text);
END;
/

