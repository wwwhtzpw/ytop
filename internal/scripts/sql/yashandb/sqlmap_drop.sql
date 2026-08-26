-- File Name: sqlmap_drop.sql
-- Purpose: Drop a YashanDB SQLMAP (query info BEFORE and AFTER the drop)
-- Created: 20260801  by  huangtingzhong
-- Updated: 20260803 by huangtingzhong
--
-- Usage: ytop/yasql -f sqlmap_drop.sql   (prompts sqlmap name)
-- Note: DROP SQLMAP requires DBA. Global switch sql_map is unchanged.
-- Note: SRC/TGT preview may hit YAS-00220 if stored SQL text has invalid UTF-8;
--       preview failure must not block DROP.

SET SERVEROUTPUT ON


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Drop YashanDB SQLMAP (DROP SQLMAP)                                     |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT mapname PROMPT 'Enter mapname (sqlmap name to drop): '

DECLARE
  v_name VARCHAR2(128) := TRIM('&&mapname');
  v_cnt  NUMBER;

  PROCEDURE bar(p_title IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 78, '-'));
    IF p_title IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE(p_title);
    END IF;
  END;

  -- Preview never raises; printable ASCII only (avoids YAS-00220 on broken UTF-8 CLOB)
  FUNCTION show_lob(p_clob IN CLOB, p_len IN PLS_INTEGER DEFAULT 110) RETURN VARCHAR2 IS
    c_max_chars CONSTANT PLS_INTEGER := 100;
    v_len   PLS_INTEGER;
    v_take  PLS_INTEGER;
    v_out   VARCHAR2(4000) := '';
    v_ch    VARCHAR2(8);
    v_i     PLS_INTEGER;
    v_code  PLS_INTEGER;
    v_ok    BOOLEAN;
  BEGIN
    IF p_clob IS NULL THEN
      RETURN '(NULL)';
    END IF;
    BEGIN
      v_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
      IF v_len = 0 THEN
        RETURN '(empty)';
      END IF;
      v_take := LEAST(NVL(p_len, 100), c_max_chars, v_len);
      v_i := 1;
      WHILE v_i <= v_take LOOP
        BEGIN
          v_ch := DBMS_LOB.SUBSTR(p_clob, 1, v_i);
          v_ok := TRUE;
        EXCEPTION
          WHEN OTHERS THEN
            v_out := v_out || '?';
            v_ok := FALSE;
        END;
        IF v_ok THEN
          IF v_ch IS NULL THEN
            EXIT;
          END IF;
          BEGIN
            IF LENGTHB(v_ch) = 1 THEN
              v_code := ASCII(v_ch);
              IF v_code BETWEEN 32 AND 126 THEN
                v_out := v_out || v_ch;
              ELSE
                v_out := v_out || '?';
              END IF;
            ELSE
              v_out := v_out || '?';
            END IF;
          EXCEPTION
            WHEN OTHERS THEN
              v_out := v_out || '?';
          END;
        END IF;
        v_i := v_i + 1;
      END LOOP;
      IF v_i <= v_len THEN
        v_out := v_out || '...';
      END IF;
      RETURN v_out;
    EXCEPTION
      WHEN OTHERS THEN
        RETURN '(omitted len=' || NVL(TO_CHAR(v_len), '?') ||
               '; preview failed: ' || REPLACE(SQLERRM, CHR(10), ' ') || ')';
    END;
  END;

  PROCEDURE show_info(p_name IN VARCHAR2) IS
    v_user VARCHAR2(64);
    v_hv   NUMBER;
    v_st   CLOB;
    v_mt   CLOB;
    v_n    NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_n FROM SYS.SQL_MAP$ WHERE UPPER(name) = UPPER(p_name);
    IF v_n = 0 THEN
      DBMS_OUTPUT.PUT_LINE('  (sqlmap not found: ' || p_name || ')');
      RETURN;
    END IF;
    SELECT user_name, hash_value, sql_text, sqlmap_text
      INTO v_user, v_hv, v_st, v_mt
      FROM SYS.SQL_MAP$
     WHERE UPPER(name) = UPPER(p_name)
       AND ROWNUM = 1;
    DBMS_OUTPUT.PUT_LINE('  name=' || p_name || ' user_name=' || v_user
                         || ' hash_value=' || v_hv);
    BEGIN
      DBMS_OUTPUT.PUT_LINE('  SRC : ' || show_lob(v_st, 110));
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  SRC : (preview failed: ' ||
          REPLACE(SQLERRM, CHR(10), ' ') || ')');
    END;
    BEGIN
      DBMS_OUTPUT.PUT_LINE('  TGT : ' || show_lob(v_mt, 110));
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  TGT : (preview failed: ' ||
          REPLACE(SQLERRM, CHR(10), ' ') || ')');
    END;
  END;

BEGIN
  IF v_name IS NULL OR LENGTH(TRIM(v_name)) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: sqlmap name is required (cannot be blank).');
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM SYS.SQL_MAP$ WHERE UPPER(name) = UPPER(v_name);
  IF v_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: sqlmap not found: ' || v_name || '. Nothing to do.');
    RETURN;
  END IF;

  bar('[BEFORE drop] sqlmap = ' || v_name);
  BEGIN
    show_info(v_name);
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  WARN: before-drop preview failed: ' || SQLERRM);
      DBMS_OUTPUT.PUT_LINE('  (continuing DROP)');
  END;

  EXECUTE IMMEDIATE 'DROP SQLMAP ' || v_name;
  DBMS_OUTPUT.PUT_LINE('>> DROP SQLMAP ' || v_name || ' executed.');

  bar('[AFTER drop]');
  SELECT COUNT(*) INTO v_cnt FROM SYS.SQL_MAP$ WHERE UPPER(name) = UPPER(v_name);
  IF v_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  confirmed: sqlmap ' || v_name || ' removed.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  WARN: sqlmap still exists!');
  END IF;
  bar();
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
    RAISE;
END;
/
