-- File Name: outline_create_by_sqlid.sql
-- Purpose: Create OUTLINE from sql_id + hint (ON sql_id USING HINT, no SQL text change)
-- Created: 20260801  by  huangtingzhong
-- Updated: 20260809 by huangtingzhong (preview sql_fulltext via CLOB; avoid VARCHAR2 32K)
--
-- Usage: ytop/yasql -f outline_create_by_sqlid.sql
--   source_sql_id : sql_id of the source SQL in v$sql
--   hint          : hint body, e.g. FULL(t) / INDEX(t idx) (WITHOUT /*+ */)
-- Mechanism (YashanDB 23.5+):
--   CREATE OUTLINE name ON '<sql_id>' USING HINT /*+ <hint> */;
--   Matches original SQL by sql_id; application SQL text need not embed hints.
-- Activate:
--   ALTER SESSION SET use_stored_outlines = TRUE;   (or TRUE / category at system)
-- Errors (RAISE_APPLICATION_ERROR, positive 302xx):
--   30201 source sql_id not in v$sql
--   30203 v$sql not accessible
--   30204 hint is empty
--   30205 CREATE OUTLINE failed

SET SERVEROUTPUT ON


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Create OUTLINE from sql_id + hint (USING HINT, original SQL unchanged) |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT source_sqlid PROMPT 'Enter source_sqlid (v$sql.sql_id): '
ACCEPT hint PROMPT 'Enter hint body (e.g. FULL(t), without /*+ */): '

DECLARE
  v_sqlid     VARCHAR2(32)   := TRIM('&&source_sqlid');
  v_hint      VARCHAR2(4000) := TRIM('&&hint');
  v_src       CLOB;
  v_name      VARCHAR2(128);
  v_exists    NUMBER;
  v_dummy     NUMBER;
  v_ddl       VARCHAR2(32767);

  FUNCTION err_msg(p_prefix IN VARCHAR2, p_detail IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(p_prefix || NVL(p_detail, ''), 1, 900);
  END;

BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'SELECT 1 FROM v$sql WHERE ROWNUM = 1' INTO v_dummy;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(30203, err_msg('v$sql not accessible: ', SQLERRM));
  END;

  IF v_sqlid IS NULL OR LENGTH(TRIM(v_sqlid)) = 0 THEN
    RAISE_APPLICATION_ERROR(30201, 'source_sqlid is required');
  END IF;

  SELECT COUNT(*) INTO v_exists FROM v$sql WHERE sql_id = v_sqlid;
  IF v_exists = 0 THEN
    RAISE_APPLICATION_ERROR(30201, 'Source sql_id not found in v$sql: ' || v_sqlid);
  END IF;

  IF v_hint IS NULL OR LENGTH(TRIM(v_hint)) = 0 THEN
    RAISE_APPLICATION_ERROR(30204, 'hint is empty; provide hint body e.g. FULL(t)');
  END IF;

  SELECT sql_fulltext
    INTO v_src
    FROM (
      SELECT sql_fulltext
        FROM v$sql
       WHERE sql_id = v_sqlid
         AND sql_fulltext IS NOT NULL
       ORDER BY DBMS_LOB.GETLENGTH(sql_fulltext) DESC NULLS LAST
    )
   WHERE ROWNUM = 1;

  v_name := 'ol_' || v_sqlid || '_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISS');
  BEGIN
    EXECUTE IMMEDIATE 'DROP OUTLINE ' || v_name;
  EXCEPTION
    WHEN OTHERS THEN NULL;
  END;

  -- ON sql_id USING HINT: outline matches original SQL; hint stored separately
  v_ddl := 'CREATE OUTLINE ' || v_name
        || ' ON ''' || v_sqlid || ''''
        || ' USING HINT /*+ ' || v_hint || ' */';

  BEGIN
    EXECUTE IMMEDIATE v_ddl;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('CREATE OUTLINE failed: ' || SQLERRM);
      DBMS_OUTPUT.PUT_LINE('DDL was: ' || v_ddl);
      RAISE_APPLICATION_ERROR(30205, err_msg('CREATE OUTLINE failed: ', SQLERRM));
  END;

  DBMS_OUTPUT.PUT_LINE('OUTLINE created: ' || v_name);
  DBMS_OUTPUT.PUT_LINE('  source sql_id : ' || v_sqlid);
  DBMS_OUTPUT.PUT_LINE('  hint          : /*+ ' || v_hint || ' */');
  DBMS_OUTPUT.PUT_LINE(
    '  SQL preview   : ' || SUBSTR(DBMS_LOB.SUBSTR(v_src, 100, 1), 1, 100));
  DBMS_OUTPUT.PUT_LINE('Rollback DDL : DROP OUTLINE ' || v_name || ';');
  DBMS_OUTPUT.PUT_LINE('Activate     : ALTER SESSION SET use_stored_outlines = TRUE;');
  DBMS_OUTPUT.PUT_LINE('Scripts      : outline.sql / outline_enable.sql / outline_disable.sql / outline_drop.sql');
END;
/
