-- File Name: sqlmap_create_awr_by_sqlid.sql
-- Purpose: Create SQLMAP from gv$sql or AWR by sql_id
-- Created: 20260803  by  huangtingzhong
--
-- Usage: ytop -f sqlmap_create_awr_by_sqlid.sql
--   Empty target_sqlid: preview only (print CREATE SQLMAP DDL, no execute);
--   map_sql uses same text as source.
-- Requires: DBA; SQL_MAP=true for mapping to take effect.
--
-- SQL text lookup (source and target), priority:
--   1) gv$sql.sql_fulltext (+ hash_value from same row)
--   2) WRH$_SQLTEXT.sql_fulltext (CLOB) when column exists
--   3) WRH$_SQLTEXT.sql_text (VARCHAR; may truncate at 1000 -- WARN)
--
-- Note: SQLMAP matcher key is HASH_VALUE of source text. CREATE via DBMS_SQL
--       lets the engine set hash from text. Stub+UPDATE fallback needs
--       hash from gv$sql; if text came only from AWR, stub path is skipped.
-- Path:
--   1) CREATE SQLMAP via DBMS_SQL.PARSE(CLOB)+EXECUTE;
--   2) If DBMS_SQL fails and gv$ hash is known: stub + UPDATE SYS.SQL_MAP$
--      (does NOT run ALTER SYSTEM; print manual reload hint: sql_map=TRUE).
-- Updated: 20260809 by huangtingzhong

SET SERVEROUTPUT ON


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Create SQLMAP from sql_id (gv$sql / WRH$_SQLTEXT)                      |
PROMPT +------------------------------------------------------------------------+
PROMPT
PROMPT Enter source_sqlid (required):
PROMPT Enter target_sqlid (empty=preview only):

DECLARE
  c_max_sql_bytes  CONSTANT PLS_INTEGER := 32000;

  v_source_sqlid   VARCHAR2(32)  := TRIM('&&source_sqlid');
  v_target_sqlid   VARCHAR2(32)  := TRIM('&&target_sqlid');
  v_preview_only   BOOLEAN;
  v_source_sql     CLOB;
  v_target_sql     CLOB;
  v_src_from       VARCHAR2(64);
  v_tgt_from       VARCHAR2(64);
  v_map_name       VARCHAR2(128);
  v_ddl            CLOB;
  v_q              VARCHAR2(1) := CHR(39);
  v_seg            VARCHAR2(4000);
  v_dummy          NUMBER;
  v_sql_map        VARCHAR2(16);
  v_src_len        NUMBER;
  v_tgt_len        NUMBER;
  v_ddl_len        NUMBER;
  v_ddl_ready      BOOLEAN := FALSE;
  v_over_limit     BOOLEAN := FALSE;
  v_src_hash       NUMBER;
  v_tgt_hash       NUMBER;
  v_stub_ddl       VARCHAR2(1000);
  v_create_err     VARCHAR2(512);
  v_gl_src         NUMBER;
  v_gl_tgt         NUMBER;
  v_row_hash       NUMBER;
  v_has_awr_ft     PLS_INTEGER := 0;
  v_gv_ok          BOOLEAN := FALSE;

  FUNCTION is_empty_target(p_sqlid IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN p_sqlid IS NULL OR LENGTH(TRIM(p_sqlid)) = 0;
  END;

  FUNCTION clob_len(p IN CLOB) RETURN NUMBER IS
  BEGIN
    IF p IS NULL THEN
      RETURN 0;
    END IF;
    RETURN DBMS_LOB.GETLENGTH(p);
  END;

  PROCEDURE put_long_line(p_text IN CLOB) IS
    c_chunk CONSTANT PLS_INTEGER := 4000;
    v_len   PLS_INTEGER;
    v_pos   PLS_INTEGER := 1;
  BEGIN
    IF p_text IS NULL OR DBMS_LOB.GETLENGTH(p_text) = 0 THEN
      RETURN;
    END IF;
    v_len := DBMS_LOB.GETLENGTH(p_text);
    WHILE v_pos <= v_len LOOP
      DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(p_text, c_chunk, v_pos));
      v_pos := v_pos + c_chunk;
    END LOOP;
  END;

  PROCEDURE print_fail(p_where IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(p_where || ' (original error, not re-raised):');
    DBMS_OUTPUT.PUT_LINE('SQLCODE=' || SQLCODE);
    DBMS_OUTPUT.PUT_LINE('SQLERRM=' || SQLERRM);
    BEGIN
      DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_STACK);
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;
    IF v_ddl_ready THEN
      IF NVL(v_ddl_len, 0) > c_max_sql_bytes THEN
        DBMS_OUTPUT.PUT_LINE(
          '-- CREATE SQLMAP DDL omitted here (ddl_len=' || v_ddl_len ||
          ' > ' || c_max_sql_bytes || '); prefer DBMS_SQL path or sqlmap_gen_ddl.sql');
      ELSE
        DBMS_OUTPUT.PUT_LINE('-- CREATE SQLMAP DDL (copy and run manually if needed):');
        put_long_line(v_ddl);
        DBMS_OUTPUT.PUT_LINE('-- end DDL');
      END IF;
    ELSE
      DBMS_OUTPUT.PUT_LINE('-- DDL not built yet (failed before DDL assemble).');
    END IF;
  END;

  PROCEDURE append_sql_escaped(p_ddl IN OUT NOCOPY CLOB, p_sql IN CLOB) IS
    v_esc CLOB;
  BEGIN
    v_esc := REPLACE(p_sql, '''', '''''');
    IF v_esc IS NOT NULL AND DBMS_LOB.GETLENGTH(v_esc) > 0 THEN
      DBMS_LOB.APPEND(p_ddl, v_esc);
    END IF;
  END;

  PROCEDURE report_success(p_via IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('SQLMAP created: ' || v_map_name || ' (via ' || p_via || ')');
    DBMS_OUTPUT.PUT_LINE('  source sql_id: ' || v_source_sqlid || '  from=' || v_src_from);
    DBMS_OUTPUT.PUT_LINE('  target sql_id: ' || v_target_sqlid || '  from=' || v_tgt_from);
    DBMS_OUTPUT.PUT_LINE('Rollback DDL : DROP SQLMAP ' || v_map_name || ';');
  END;

  -- Resolve sql text: gv$sql first, then WRH$_SQLTEXT (fulltext CLOB / sql_text)
  PROCEDURE fetch_sql_text(
    p_sqlid   IN  VARCHAR2,
    p_text    OUT CLOB,
    p_hash    OUT NUMBER,
    p_from    OUT VARCHAR2
  ) IS
    v_ft CLOB;
  BEGIN
    p_text := NULL;
    p_hash := NULL;
    p_from := NULL;

    IF p_sqlid IS NULL OR LENGTH(TRIM(p_sqlid)) = 0 THEN
      RETURN;
    END IF;

    IF v_gv_ok THEN
      BEGIN
        SELECT sql_fulltext, hash_value
          INTO p_text, p_hash
          FROM (
            SELECT sql_fulltext, hash_value
              FROM gv$sql
             WHERE sql_id = p_sqlid
               AND sql_fulltext IS NOT NULL
             ORDER BY DBMS_LOB.GETLENGTH(sql_fulltext) DESC NULLS LAST,
                      inst_id,
                      child_number
          )
         WHERE ROWNUM = 1;
        p_from := 'gv$sql.sql_fulltext';
        RETURN;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          NULL;
      END;
    END IF;

    IF v_has_awr_ft > 0 THEN
      BEGIN
        EXECUTE IMMEDIATE
          'SELECT sql_fulltext FROM (' ||
          '  SELECT sql_fulltext FROM sys.wrh$_sqltext' ||
          '   WHERE sql_id = :1 AND sql_fulltext IS NOT NULL' ||
          '   ORDER BY DBMS_LOB.GETLENGTH(sql_fulltext) DESC NULLS LAST, snap_id DESC' ||
          ') WHERE ROWNUM = 1'
          INTO v_ft
          USING p_sqlid;
        IF v_ft IS NOT NULL AND NVL(DBMS_LOB.GETLENGTH(v_ft), 0) > 0 THEN
          p_text := v_ft;
          p_from := 'WRH$_SQLTEXT.sql_fulltext';
          RETURN;
        END IF;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          NULL;
        WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE(
            'WARN: WRH$_SQLTEXT.sql_fulltext lookup failed for ' ||
            p_sqlid || ': ' || SQLERRM);
      END;
    END IF;

    BEGIN
      SELECT TO_CLOB(sql_text)
        INTO p_text
        FROM (
          SELECT sql_text
            FROM sys.wrh$_sqltext
           WHERE sql_id = p_sqlid
             AND sql_text IS NOT NULL
           ORDER BY LENGTH(sql_text) DESC NULLS LAST, snap_id DESC
        )
       WHERE ROWNUM = 1;
      p_from := 'WRH$_SQLTEXT.sql_text (may truncate at 1000)';
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_text := NULL;
        p_from := NULL;
    END;
  END;

  PROCEDURE create_via_dbms_sql IS
    v_cur INTEGER;
    v_ret NUMBER;
  BEGIN
    v_cur := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(v_cur, v_ddl, 1);
    v_ret := DBMS_SQL.EXECUTE(v_cur);
    DBMS_SQL.CLOSE_CURSOR(v_cur);
    report_success('DBMS_SQL');
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        IF DBMS_SQL.IS_OPEN(v_cur) THEN
          DBMS_SQL.CLOSE_CURSOR(v_cur);
        END IF;
      EXCEPTION
        WHEN OTHERS THEN NULL;
      END;
      RAISE;
  END;

  PROCEDURE create_via_sql_map_patch IS
    v_stored_name VARCHAR2(128);
    v_upd_cnt     NUMBER;
  BEGIN
    IF v_src_hash IS NULL THEN
      DBMS_OUTPUT.PUT_LINE(
        'ERROR: source hash_value unknown (text from AWR only); ' ||
        'stub+UPDATE needs gv$sql.hash_value -- cannot fall back');
      RETURN;
    END IF;

    BEGIN
      EXECUTE IMMEDIATE 'DROP SQLMAP ' || v_map_name;
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;

    v_stub_ddl :=
      'CREATE SQLMAP ' || v_map_name ||
      ' (ALL, ''SELECT 1 FROM dual /*ytop_stub_src_' || v_map_name || '*/'', ' ||
      '''SELECT 1 FROM dual /*ytop_stub_tgt_' || v_map_name || '*/'')';
    EXECUTE IMMEDIATE v_stub_ddl;

    SELECT name INTO v_stored_name
      FROM SYS.SQL_MAP$
     WHERE UPPER(name) = UPPER(v_map_name)
       AND ROWNUM = 1;
    v_map_name := v_stored_name;
    DBMS_OUTPUT.PUT_LINE('Stub SQLMAP created: ' || v_map_name);

    UPDATE SYS.SQL_MAP$
       SET sql_text       = v_source_sql,
           sqlmap_text    = v_target_sql,
           sql_textlen    = v_src_len,
           sqlmap_textlen = v_tgt_len,
           hash_value     = v_src_hash,
           user_name      = 'ALL'
     WHERE name = v_map_name;
    v_upd_cnt := SQL%ROWCOUNT;

    IF v_upd_cnt <> 1 THEN
      RAISE_APPLICATION_ERROR(
        -20001,
        'UPDATE SYS.SQL_MAP$ affected ' || v_upd_cnt || ' rows for ' || v_map_name);
    END IF;
    COMMIT;

    SELECT DBMS_LOB.GETLENGTH(sql_text),
           DBMS_LOB.GETLENGTH(sqlmap_text),
           hash_value
      INTO v_gl_src, v_gl_tgt, v_row_hash
      FROM SYS.SQL_MAP$
     WHERE name = v_map_name;

    DBMS_OUTPUT.PUT_LINE(
      'Patched SYS.SQL_MAP$: src_clob=' || v_gl_src ||
      ' tgt_clob=' || v_gl_tgt || ' hash=' || v_row_hash);

    -- UPDATE alone does not reload matcher; do not ALTER SYSTEM here.
    DBMS_OUTPUT.PUT_LINE(
      'WARN: SQL_MAP$ patched; matcher not reloaded by this script.');
    DBMS_OUTPUT.PUT_LINE(
      '  Reload manually if needed: ALTER SYSTEM SET sql_map = TRUE;');

    report_success('stub+UPDATE SQL_MAP$');
  END;

BEGIN
  -- Probe gv$sql (optional; AWR can still work if absent)
  BEGIN
    EXECUTE IMMEDIATE 'SELECT 1 FROM gv$sql WHERE ROWNUM = 1' INTO v_dummy;
    v_gv_ok := TRUE;
  EXCEPTION
    WHEN OTHERS THEN
      v_gv_ok := FALSE;
      DBMS_OUTPUT.PUT_LINE(
        'WARN: gv$sql not accessible (' || SQLERRM || '); will use AWR only');
  END;

  SELECT COUNT(*)
    INTO v_has_awr_ft
    FROM dba_tab_columns
   WHERE owner = 'SYS'
     AND table_name = 'WRH$_SQLTEXT'
     AND column_name = 'SQL_FULLTEXT';

  IF v_source_sqlid IS NULL OR LENGTH(v_source_sqlid) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: source_sqlid is required');
    RETURN;
  END IF;

  fetch_sql_text(v_source_sqlid, v_source_sql, v_src_hash, v_src_from);
  IF v_source_sql IS NULL OR clob_len(v_source_sql) = 0 THEN
    DBMS_OUTPUT.PUT_LINE(
      'ERROR: source sql_id not found in gv$sql or WRH$_SQLTEXT: ' || v_source_sqlid);
    RETURN;
  END IF;
  DBMS_OUTPUT.PUT_LINE(
    'source from=' || v_src_from ||
    ' len=' || clob_len(v_source_sql) ||
    ' hash=' || NVL(TO_CHAR(v_src_hash), '<none>'));
  IF INSTR(v_src_from, 'sql_text') > 0 THEN
    DBMS_OUTPUT.PUT_LINE(
      'WARN: source text from VARCHAR sql_text may be truncated; map may not match');
  END IF;

  v_preview_only := is_empty_target(v_target_sqlid);

  IF NOT v_preview_only THEN
    IF LOWER(v_source_sqlid) = LOWER(v_target_sqlid) THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: source sql_id equals target sql_id (' ||
                           v_source_sqlid || ') - nothing to map');
      RETURN;
    END IF;
    fetch_sql_text(v_target_sqlid, v_target_sql, v_tgt_hash, v_tgt_from);
    IF v_target_sql IS NULL OR clob_len(v_target_sql) = 0 THEN
      DBMS_OUTPUT.PUT_LINE(
        'ERROR: target sql_id not found in gv$sql or WRH$_SQLTEXT: ' || v_target_sqlid);
      RETURN;
    END IF;
    DBMS_OUTPUT.PUT_LINE(
      'target from=' || v_tgt_from ||
      ' len=' || clob_len(v_target_sql));
    IF INSTR(v_tgt_from, 'sql_text') > 0 THEN
      DBMS_OUTPUT.PUT_LINE(
        'WARN: target text from VARCHAR sql_text may be truncated');
    END IF;
  END IF;

  BEGIN
    IF v_preview_only THEN
      v_target_sql := v_source_sql;
      v_tgt_from := 'same as source (preview)';
    END IF;

    v_src_len := clob_len(v_source_sql);
    v_tgt_len := clob_len(v_target_sql);
    DBMS_OUTPUT.PUT_LINE('source_len=' || v_src_len || ' target_len=' || v_tgt_len);

    IF v_preview_only THEN
      v_map_name := 'map_' || v_source_sqlid || '_'
                 || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISS');
    ELSE
      v_map_name := 'map_' || v_source_sqlid || '_' || v_target_sqlid || '_'
                 || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISS');
    END IF;

    DBMS_LOB.CREATETEMPORARY(v_ddl, TRUE);
    v_seg := 'CREATE SQLMAP ' || v_map_name || ' (ALL, ' || v_q;
    DBMS_LOB.WRITEAPPEND(v_ddl, LENGTH(v_seg), v_seg);
    append_sql_escaped(v_ddl, v_source_sql);
    v_seg := v_q || ', ' || v_q;
    DBMS_LOB.WRITEAPPEND(v_ddl, LENGTH(v_seg), v_seg);
    append_sql_escaped(v_ddl, v_target_sql);
    v_seg := v_q || ')';
    DBMS_LOB.WRITEAPPEND(v_ddl, LENGTH(v_seg), v_seg);
    v_ddl_ready := TRUE;
    v_ddl_len := clob_len(v_ddl);
    DBMS_OUTPUT.PUT_LINE('ddl_len=' || v_ddl_len);

    v_over_limit := (v_src_len > c_max_sql_bytes)
                 OR (v_tgt_len > c_max_sql_bytes)
                 OR (v_ddl_len > c_max_sql_bytes);

    IF v_preview_only THEN
      DBMS_OUTPUT.PUT_LINE('-- preview only (target_sqlid empty), not executed');
      DBMS_OUTPUT.PUT_LINE('  source sql_id: ' || v_source_sqlid || ' from=' || v_src_from);
      DBMS_OUTPUT.PUT_LINE('  map_sql: same as source');
      IF v_over_limit THEN
        DBMS_OUTPUT.PUT_LINE(
          '-- NOTE: over ' || c_max_sql_bytes ||
          ' bytes; real create will use DBMS_SQL.PARSE(CLOB)');
      END IF;
      DBMS_OUTPUT.PUT_LINE('-- CREATE SQLMAP DDL:');
      put_long_line(v_ddl);
      RETURN;
    END IF;

    BEGIN
      SELECT UPPER(TRIM(value)) INTO v_sql_map
        FROM v$parameter
       WHERE LOWER(name) = 'sql_map'
         AND ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_sql_map := NULL;
    END;

    IF NVL(v_sql_map, 'FALSE') NOT IN ('TRUE', 'ON', '1', 'YES') THEN
      DBMS_OUTPUT.PUT_LINE(
        'WARN: SQL_MAP is not enabled; CREATE SQLMAP succeeds but mapping is inactive.');
      DBMS_OUTPUT.PUT_LINE('  Enable online (no restart): ALTER SYSTEM SET sql_map = TRUE;');
    END IF;

    BEGIN
      EXECUTE IMMEDIATE 'DROP SQLMAP ' || v_map_name;
      DBMS_OUTPUT.PUT_LINE('Dropped existing SQLMAP: ' || v_map_name);
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;

    IF v_over_limit THEN
      DBMS_OUTPUT.PUT_LINE(
        'INFO: SQL/DDL > ' || c_max_sql_bytes ||
        ' bytes; CREATE via DBMS_SQL.PARSE(CLOB)');
    END IF;

    BEGIN
      create_via_dbms_sql;
    EXCEPTION
      WHEN OTHERS THEN
        v_create_err := SQLERRM;
        DBMS_OUTPUT.PUT_LINE('DBMS_SQL CREATE SQLMAP failed: ' || v_create_err);
        IF v_src_hash IS NULL THEN
          DBMS_OUTPUT.PUT_LINE(
            'ERROR: cannot stub+UPDATE without gv$sql.hash_value ' ||
            '(source text from AWR only); fix DBMS_SQL error or bring SQL into gv$sql');
          print_fail('DBMS_SQL failed; stub fallback skipped (no hash)');
        ELSE
          DBMS_OUTPUT.PUT_LINE('INFO: falling back to stub+UPDATE SYS.SQL_MAP$');
          BEGIN
            create_via_sql_map_patch;
          EXCEPTION
            WHEN OTHERS THEN
              print_fail('DBMS_SQL failed; stub+UPDATE SQL_MAP$ also failed');
          END;
        END IF;
    END;
  EXCEPTION
    WHEN OTHERS THEN
      print_fail('SQLMAP script failed');
  END;
END;
/
