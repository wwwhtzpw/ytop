-- File Name: sqlmap.sql
-- Purpose: View YashanDB SQLMAP (list all + look up by sqlmap name or sql_id)
-- Created: 20260731  by  huangtingzhong
-- Updated: 20260814 by huangtingzhong (keep --define; no UNDEFINE wipe)
--
-- Usage: ytop/yasql -f sqlmap.sql   (prompts for sql_id)
--        ytop -E -f sqlmap.sql --define sqlid=   (blank = list all)
--   blank            : list all SQLMAPs (lookup mode off)
--   <sqlmap name>    : show that sqlmap's definition directly from SYS.SQL_MAP$ (no v$sql needed)
--   <sql_id>         : show sqlmaps covering that SQL, via v$sql.HASH_VALUE (needs the SQL in v$sql)
--
-- Notes (measured on YashanDB 23.5):
--   * SYS.SQL_MAP$ has no SQL_ID column -- only HASH_VALUE. So:
--     - lookup by name is direct (SQL_MAP$.name);
--     - lookup by sql_id goes through v$sql.HASH_VALUE = SQL_MAP$.HASH_VALUE (fails if aged out);
--     - if hash misses, also try name prefix MAP_<sql_id>_% / map_<sql_id>_% and warn on hash mismatch;
--     - the list section reverse-looks-up sql_id from v$sql via HASH_VALUE (n/a if aged out).
--   * Whether a sqlmap is "actually applied" cannot be seen from the catalog (plan_hash / VERSION
--     are unreliable). Reliable check = run the source SQL and compare against TARGET.
--   * SRC/TGT preview: CLOB may contain broken UTF-8 (YAS-00220). show_lob only appends
--     printable ASCII; other bytes become '?'. One bad map must not abort the whole list.

SET SERVEROUTPUT ON

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | View YashanDB SQLMAP (blank=list all; name or sql_id=lookup)           |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT sqlid PROMPT 'Enter sqlid (blank=list all; or sqlmap name / sql_id): '

DECLARE
  c_pad  CONSTANT VARCHAR2(2) := '  ';
  v_input        VARCHAR2(128) := TRIM('&&sqlid');
  v_sql_map      VARCHAR2(16);
  v_sql_text     CLOB;
  v_hash         NUMBER;
  v_execs        NUMBER;
  v_last         VARCHAR2(32);
  v_matched      NUMBER := 0;
  v_total        NUMBER := 0;
  v_has_input    BOOLEAN := FALSE;
  v_sid          VARCHAR2(16);
  v_by_name      NUMBER := 0;

  FUNCTION has_value(p IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN p IS NOT NULL AND LENGTH(TRIM(p)) > 0;
  END;

  -- Preview never raises; printable ASCII only (avoids YAS-00220 on broken UTF-8 CLOB)
  FUNCTION show_lob(p_clob IN CLOB, p_len IN PLS_INTEGER DEFAULT 100) RETURN VARCHAR2 IS
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
            -- single-byte printable ASCII only; multi-byte / control -> '?'
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
        RETURN '(unprintable len=' || NVL(TO_CHAR(v_len), '?') ||
               '; ' || REPLACE(SQLERRM, CHR(10), ' ') || ')';
    END;
  END;

  PROCEDURE bar(p_title IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 78, '-'));
    IF p_title IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE(p_title);
    END IF;
  END;

  PROCEDURE show_map(p_name IN VARCHAR2, p_user IN VARCHAR2, p_hv IN NUMBER,
                     p_st IN CLOB, p_mt IN CLOB) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('  map name    : ' || p_name);
    DBMS_OUTPUT.PUT_LINE('  user_name   : ' || p_user || '   hash_value: ' || p_hv);
    BEGIN
      DBMS_OUTPUT.PUT_LINE('  SOURCE SQL  : ' || show_lob(p_st, 100));
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  SOURCE SQL  : (preview failed: ' ||
          REPLACE(SQLERRM, CHR(10), ' ') || ')');
    END;
    BEGIN
      DBMS_OUTPUT.PUT_LINE('  TARGET SQL  : ' || show_lob(p_mt, 100));
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  TARGET SQL  : (preview failed: ' ||
          REPLACE(SQLERRM, CHR(10), ' ') || ')');
    END;
  END;

BEGIN
  BEGIN
    SELECT UPPER(TRIM(value)) INTO v_sql_map
      FROM v$parameter
     WHERE LOWER(name) = 'sql_map' AND ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN v_sql_map := NULL;
  END;

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '=== YashanDB SQLMAP View ===');
  DBMS_OUTPUT.PUT_LINE('sql_map parameter : ' || NVL(v_sql_map, '(not found)')
    || CASE WHEN NVL(v_sql_map,'FALSE') NOT IN ('TRUE','ON','1','YES')
            THEN '   [WARN: disabled, mappings inactive. Enable: ALTER SYSTEM SET sql_map=TRUE]'
            ELSE '' END);

  v_has_input := has_value(v_input);

  -- lookup mode
  IF v_has_input THEN
    bar('[lookup] input = ' || v_input);

    -- 1) try as a sqlmap NAME first (direct, SYS.SQL_MAP$ has NAME; no v$sql needed)
    SELECT COUNT(*) INTO v_matched FROM SYS.SQL_MAP$ WHERE UPPER(name) = UPPER(v_input);
    IF v_matched > 0 THEN
      DBMS_OUTPUT.PUT_LINE('matched by sqlmap NAME (' || v_matched || '):');
      FOR r IN (SELECT name, user_name, sql_text st, sqlmap_text mt, hash_value hv
                  FROM SYS.SQL_MAP$ WHERE UPPER(name) = UPPER(v_input) ORDER BY name) LOOP
        show_map(r.name, r.user_name, r.hv, r.st, r.mt);
      END LOOP;
    ELSE
      -- 2) try as a sql_id (via v$sql.HASH_VALUE, since SQL_MAP$ has no sql_id column)
      BEGIN
        SELECT sql_fulltext, hash_value, executions,
               TO_CHAR(last_active_time, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_sql_text, v_hash, v_execs, v_last
          FROM v$sql
         WHERE sql_id = v_input
           AND ROWNUM = 1;
        DBMS_OUTPUT.PUT_LINE('input is a sql_id in v$sql:');
        BEGIN
          DBMS_OUTPUT.PUT_LINE('  SQL fulltext : ' || show_lob(v_sql_text, 120));
        EXCEPTION
          WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('  SQL fulltext : (preview failed: ' ||
              REPLACE(SQLERRM, CHR(10), ' ') || ')');
        END;
        DBMS_OUTPUT.PUT_LINE('  hash_value=' || v_hash || '  executions=' || v_execs ||
                             '  last_active=' || v_last);
        SELECT COUNT(*) INTO v_matched FROM SYS.SQL_MAP$ WHERE hash_value = v_hash;
        IF v_matched > 0 THEN
          DBMS_OUTPUT.PUT_LINE('  sqlmap matched: ' || v_matched || ' (by hash_value)');
          FOR r IN (SELECT name, user_name, sql_text st, sqlmap_text mt, hash_value hv
                      FROM SYS.SQL_MAP$ WHERE hash_value = v_hash ORDER BY name) LOOP
            show_map(r.name, r.user_name, r.hv, r.st, r.mt);
          END LOOP;
        ELSE
          -- 3) name-prefix fallback (map may exist but hash stale / different child)
          SELECT COUNT(*) INTO v_by_name
            FROM SYS.SQL_MAP$
           WHERE UPPER(name) LIKE 'MAP_' || UPPER(v_input) || '_%'
              OR UPPER(name) LIKE UPPER(v_input) || '_%';
          IF v_by_name > 0 THEN
            DBMS_OUTPUT.PUT_LINE('  sqlmap matched: NONE by hash_value=' || v_hash);
            DBMS_OUTPUT.PUT_LINE('  name-prefix hit: ' || v_by_name ||
              ' (MAP_' || UPPER(v_input) || '_*); mapping will NOT apply until hash matches');
            FOR r IN (
              SELECT name, user_name, sql_text st, sqlmap_text mt, hash_value hv
                FROM SYS.SQL_MAP$
               WHERE UPPER(name) LIKE 'MAP_' || UPPER(v_input) || '_%'
                  OR UPPER(name) LIKE UPPER(v_input) || '_%'
               ORDER BY name
            ) LOOP
              show_map(r.name, r.user_name, r.hv, r.st, r.mt);
              IF r.hv IS NULL OR r.hv <> v_hash THEN
                DBMS_OUTPUT.PUT_LINE('  WARN: map hash=' || NVL(TO_CHAR(r.hv), 'NULL') ||
                  ' != v$sql hash=' || v_hash ||
                  ' (recreate SQLMAP from current sql_id to take effect)');
              END IF;
            END LOOP;
          ELSE
            DBMS_OUTPUT.PUT_LINE('  sqlmap matched: NONE (this SQL is not covered by any sqlmap)');
          END IF;
        END IF;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          DBMS_OUTPUT.PUT_LINE('input is neither a sqlmap name nor a sql_id in v$sql');
          DBMS_OUTPUT.PUT_LINE('(SQL_MAP$ has no sql_id column; a sql_id lookup needs the SQL still in v$sql)');
      END;
    END IF;

    DBMS_OUTPUT.PUT_LINE('[effectiveness] catalog only shows definition. To confirm it is applied:');
    DBMS_OUTPUT.PUT_LINE('   re-run the source SQL and compare result/plan against TARGET.');
  END IF;

  -- list mode: always list all; one bad CLOB must not abort remaining rows
  SELECT COUNT(*) INTO v_total FROM SYS.SQL_MAP$;
  bar('[list] all SQLMAPs (total = ' || v_total || ', sql_id reverse-lookup needs SQL in v$sql)');
  IF v_total = 0 THEN
    DBMS_OUTPUT.PUT_LINE('(empty) No SQLMAP yet. Create one with sqlmap_create_by_sqlid.sql.');
  ELSE
    FOR r IN (SELECT name, user_name, sql_text st, sqlmap_text mt, hash_value hv
                FROM SYS.SQL_MAP$ ORDER BY name) LOOP
      BEGIN
        v_sid := NULL;
        BEGIN
          SELECT sql_id INTO v_sid FROM v$sql WHERE hash_value = r.hv AND ROWNUM = 1;
        EXCEPTION
          WHEN OTHERS THEN v_sid := NULL;
        END;
        DBMS_OUTPUT.PUT_LINE(c_pad || RPAD(r.name, 34) || ' sql_id=' ||
                             RPAD(NVL(v_sid, '(n/a)'), 14) || ' hash=' || r.hv);
        BEGIN
          DBMS_OUTPUT.PUT_LINE(c_pad || '   SRC : ' || show_lob(r.st, 100));
        EXCEPTION
          WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(c_pad || '   SRC : (preview failed: ' ||
              REPLACE(SQLERRM, CHR(10), ' ') || ')');
        END;
        BEGIN
          DBMS_OUTPUT.PUT_LINE(c_pad || '   TGT : ' || show_lob(r.mt, 100));
        EXCEPTION
          WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(c_pad || '   TGT : (preview failed: ' ||
              REPLACE(SQLERRM, CHR(10), ' ') || ')');
        END;
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE(c_pad || RPAD(NVL(r.name, '?'), 34) ||
            ' [list ERROR: ' || REPLACE(SQLERRM, CHR(10), ' ') || ']');
      END;
    END LOOP;
  END IF;
  bar();
END;
/
