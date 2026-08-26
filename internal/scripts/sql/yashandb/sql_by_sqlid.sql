-- File Name: sql_by_sqlid.sql
-- Purpose: YashanDB Show SQL text by sql_id gv or AWR
-- Created: 20260516  by  huangtingzhong
--
-- Priority:
--   1) gv$sql.sql_fulltext (fallback v$sql) -- full live text
--   2) WRH$_SQLTEXT.sql_fulltext (CLOB) when column exists
--   3) WRH$_SQLTEXT.sql_text (VARCHAR, may truncate at 1000)
--
-- Usage: ytop -f sql_by_sqlid.sql
-- Example: sqlid=2y89du3xftz73

SET SERVEROUTPUT ON


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Show SQL text by sql_id (gv$sql / v$sql, else AWR WRH$_SQLTEXT)        |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT sqlid PROMPT 'Enter sqlid (sql_id): '

DECLARE
  v_sqlid   VARCHAR2(13) := LOWER(TRIM('&&sqlid'));
  v_text    CLOB;
  v_src     VARCHAR2(64);
  v_len     PLS_INTEGER;
  v_off     PLS_INTEGER;
  v_amt     PLS_INTEGER;
  v_has_ft  PLS_INTEGER := 0;
  c_chunk   CONSTANT PLS_INTEGER := 30000;

  PROCEDURE put_clob(p_clob IN CLOB) IS
  BEGIN
    IF p_clob IS NULL THEN
      RETURN;
    END IF;
    v_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    IF v_len = 0 THEN
      RETURN;
    END IF;
    v_off := 1;
    WHILE v_off <= v_len LOOP
      v_amt := LEAST(c_chunk, v_len - v_off + 1);
      DBMS_OUTPUT.PUT(DBMS_LOB.SUBSTR(p_clob, v_amt, v_off));
      v_off := v_off + v_amt;
    END LOOP;
    DBMS_OUTPUT.NEW_LINE;
  END;

BEGIN
  DBMS_OUTPUT.ENABLE(10000000);

  IF v_sqlid IS NULL OR LENGTH(v_sqlid) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('-- ERROR: sqlid is required');
    RETURN;
  END IF;

  -- 1) live cursor: prefer gv$sql, then v$sql
  BEGIN
    SELECT sql_fulltext
      INTO v_text
      FROM (
             SELECT sql_fulltext
               FROM gv$sql
              WHERE sql_id = v_sqlid
                AND sql_fulltext IS NOT NULL
              ORDER BY inst_id, child_number
           )
     WHERE ROWNUM = 1;
    v_src := 'gv$sql.sql_fulltext';
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      BEGIN
        SELECT sql_fulltext
          INTO v_text
          FROM (
                 SELECT sql_fulltext
                   FROM v$sql
                  WHERE sql_id = v_sqlid
                    AND sql_fulltext IS NOT NULL
                  ORDER BY child_number
               )
         WHERE ROWNUM = 1;
        v_src := 'v$sql.sql_fulltext';
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          v_text := NULL;
      END;
    WHEN OTHERS THEN
      -- gv$sql may be missing on some builds; try v$sql
      BEGIN
        SELECT sql_fulltext
          INTO v_text
          FROM (
                 SELECT sql_fulltext
                   FROM v$sql
                  WHERE sql_id = v_sqlid
                    AND sql_fulltext IS NOT NULL
                  ORDER BY child_number
               )
         WHERE ROWNUM = 1;
        v_src := 'v$sql.sql_fulltext';
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          v_text := NULL;
      END;
  END;

  -- 2) AWR fallback
  IF v_text IS NULL OR NVL(DBMS_LOB.GETLENGTH(v_text), 0) = 0 THEN
    SELECT COUNT(*)
      INTO v_has_ft
      FROM dba_tab_columns
     WHERE owner = 'SYS'
       AND table_name = 'WRH$_SQLTEXT'
       AND column_name = 'SQL_FULLTEXT';

    IF v_has_ft > 0 THEN
      BEGIN
        EXECUTE IMMEDIATE
          'SELECT sql_fulltext FROM (' ||
          '  SELECT sql_fulltext FROM sys.wrh$_sqltext' ||
          '   WHERE sql_id = :1 AND sql_fulltext IS NOT NULL' ||
          '   ORDER BY snap_id DESC' ||
          ') WHERE ROWNUM = 1'
          INTO v_text
          USING v_sqlid;
        v_src := 'WRH$_SQLTEXT.sql_fulltext';
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          v_text := NULL;
      END;
    END IF;

    IF v_text IS NULL OR NVL(DBMS_LOB.GETLENGTH(v_text), 0) = 0 THEN
      BEGIN
        SELECT TO_CLOB(sql_text)
          INTO v_text
          FROM (
                 SELECT sql_text
                   FROM sys.wrh$_sqltext
                  WHERE sql_id = v_sqlid
                    AND sql_text IS NOT NULL
                  ORDER BY snap_id DESC
               )
         WHERE ROWNUM = 1;
        v_src := 'WRH$_SQLTEXT.sql_text (may truncate at 1000)';
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          v_text := NULL;
      END;
    END IF;
  END IF;

  IF v_text IS NULL OR NVL(DBMS_LOB.GETLENGTH(v_text), 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('-- ERROR: sql_id not found in gv$/v$sql or WRH$_SQLTEXT: ' || v_sqlid);
    RETURN;
  END IF;

  DBMS_OUTPUT.PUT_LINE('-- sql_id=' || v_sqlid
    || '  source=' || v_src
    || '  bytes=' || NVL(DBMS_LOB.GETLENGTH(v_text), 0));
  DBMS_OUTPUT.PUT_LINE('');
  put_clob(v_text);
END;
/
