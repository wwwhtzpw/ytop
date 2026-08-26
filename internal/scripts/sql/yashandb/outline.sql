-- File Name: outline.sql
-- Purpose: View YashanDB OUTLINE (list all + look up by name / sql_id / sql_text fragment)
-- Created: 20260801  by  huangtingzhong
-- Updated: 20260809 by huangtingzhong (sql_text fragment match via CLOB chunk scan; no 32K)
--
-- Usage: ytop/yasql -f outline.sql   (prompts outline name)
--   blank : list all OUTLINEs
--   input : match by outline NAME (exact, case-insensitive), SQL_ID, or SQL_TEXT
--           fragment (substring, case-insensitive). Multiple matches are all shown.

SET SERVEROUTPUT ON

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | View YashanDB OUTLINE                                                  |
PROMPT | Input accepts one of (case-insensitive):                              |
PROMPT |   - outline NAME      (exact match)                                    |
PROMPT |   - SQL_ID            (match DBA_OUTLINES.SQL_ID)                      |
PROMPT |   - SQL_TEXT fragment (substring match)                                |
PROMPT |   - blank             (match ALL outlines)                            |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT outlinename PROMPT 'Enter outline name / sql_id / sql_text fragment (blank = all): '

DECLARE
  v_input   VARCHAR2(4000) := TRIM('&&outlinename');
  v_total   NUMBER;
  v_matched NUMBER;
  v_sid     VARCHAR2(32);

  FUNCTION has_value(p IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN p IS NOT NULL AND LENGTH(TRIM(p)) > 0;
  END;

  -- case-insensitive CLOB contains; chunk=1000 with pattern overlap (no 32K truncate)
  FUNCTION clob_contains_ci(p_clob IN CLOB, p_pat IN VARCHAR2) RETURN BOOLEAN IS
    c_chunk CONSTANT PLS_INTEGER := 1000;
    v_pat   VARCHAR2(4000) := UPPER(p_pat);
    v_plen  PLS_INTEGER;
    v_len   NUMBER;
    v_off   NUMBER := 1;
    v_amt   NUMBER;
    v_ov    PLS_INTEGER;
    v_buf   VARCHAR2(4000);
  BEGIN
    IF p_clob IS NULL OR p_pat IS NULL OR LENGTH(p_pat) = 0 THEN
      RETURN FALSE;
    END IF;
    v_plen := LENGTH(v_pat);
    IF v_plen > 3000 THEN
      RETURN FALSE;
    END IF;
    v_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    IF v_len = 0 THEN
      RETURN FALSE;
    END IF;
    v_ov := GREATEST(v_plen - 1, 0);
    WHILE v_off <= v_len LOOP
      v_amt := LEAST(c_chunk + v_ov, v_len - v_off + 1);
      v_buf := UPPER(DBMS_LOB.SUBSTR(p_clob, v_amt, v_off));
      IF INSTR(v_buf, v_pat) > 0 THEN
        RETURN TRUE;
      END IF;
      v_off := v_off + c_chunk;
    END LOOP;
    RETURN FALSE;
  END;

  FUNCTION outline_matches(p_name IN VARCHAR2, p_sqlid IN VARCHAR2,
                           p_sql IN CLOB, p_input IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    IF UPPER(p_name) = UPPER(p_input) THEN
      RETURN TRUE;
    END IF;
    IF p_sqlid IS NOT NULL AND p_sqlid = p_input THEN
      RETURN TRUE;
    END IF;
    RETURN clob_contains_ci(p_sql, p_input);
  END;

  PROCEDURE bar(p_title IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 78, '-'));
    IF p_title IS NOT NULL THEN DBMS_OUTPUT.PUT_LINE(p_title); END IF;
  END;

  PROCEDURE show_detail(p_name IN VARCHAR2) IS
    v_owner VARCHAR2(128); v_cat VARCHAR2(128); v_en VARCHAR2(32);
    v_used VARCHAR2(64); v_ts VARCHAR2(32);
    v_sqlid VARCHAR2(32); v_sql CLOB;
  BEGIN
    SELECT owner, category, enabled, used,
           TO_CHAR(timestamp,'YYYY-MM-DD HH24:MI:SS'), sql_id, sql_text
      INTO v_owner, v_cat, v_en, v_used, v_ts, v_sqlid, v_sql
      FROM dba_outlines WHERE name = p_name;
    IF v_sqlid IS NULL THEN
      BEGIN
        SELECT sql_id INTO v_sqlid FROM v$sql
         WHERE sql_fulltext LIKE SUBSTR(DBMS_LOB.SUBSTR(v_sql, 80, 1), 1, 80) || '%' AND rownum=1;
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_name, 32) || RPAD(v_owner, 9) || RPAD(v_cat, 13)
                         || RPAD(v_en, 11) || RPAD(NVL(v_used,'?'),9) || RPAD(NVL(v_sqlid,'(n/a)'),14)
                         || v_ts);
    DBMS_OUTPUT.PUT_LINE('    SQL_TEXT : ' || SUBSTR(DBMS_LOB.SUBSTR(v_sql, 180, 1), 1, 180));
    FOR h IN (SELECT node, stage, join_pos, hint FROM dba_outline_hints WHERE name = p_name
              ORDER BY node, stage, join_pos) LOOP
      DBMS_OUTPUT.PUT_LINE('    HINT[node=' || h.node || ',stage=' || h.stage
                           || ',join=' || h.join_pos || ']: '
                           || SUBSTR(DBMS_LOB.SUBSTR(h.hint, 150, 1), 1, 150));
    END LOOP;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN DBMS_OUTPUT.PUT_LINE('  outline not found: ' || p_name);
  END;

  -- match by NAME (exact, case-insensitive) / SQL_ID / SQL_TEXT fragment (full CLOB)
  FUNCTION match_count(p_input IN VARCHAR2) RETURN NUMBER IS
    v_n NUMBER := 0;
  BEGIN
    FOR r IN (SELECT name, sql_id, sql_text FROM dba_outlines) LOOP
      IF outline_matches(r.name, r.sql_id, r.sql_text, p_input) THEN
        v_n := v_n + 1;
      END IF;
    END LOOP;
    RETURN v_n;
  END;

  PROCEDURE show_matches(p_input IN VARCHAR2) IS
  BEGIN
    FOR r IN (SELECT name, sql_id, sql_text FROM dba_outlines ORDER BY name) LOOP
      IF outline_matches(r.name, r.sql_id, r.sql_text, p_input) THEN
        show_detail(r.name);
      END IF;
    END LOOP;
  END;

BEGIN
  IF has_value(v_input) THEN
    bar('[lookup] input = ' || v_input || '  (match by name / sql_id / sql_text fragment)');
    v_matched := match_count(v_input);
    IF v_matched = 0 THEN
      DBMS_OUTPUT.PUT_LINE('  no outline matched.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('  matched ' || v_matched || ' outline(s):');
      show_matches(v_input);
    END IF;
  ELSE
    -- blank input matches ALL outlines (full detail)
    bar('[lookup] blank input - matching ALL outlines');
    SELECT COUNT(*) INTO v_matched FROM dba_outlines;
    IF v_matched = 0 THEN
      DBMS_OUTPUT.PUT_LINE('  (empty) no outline.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('  showing all ' || v_matched || ' outline(s):');
      FOR r IN (SELECT name FROM dba_outlines ORDER BY name) LOOP
        show_detail(r.name);
      END LOOP;
    END IF;
  END IF;

  bar();
END;
/
