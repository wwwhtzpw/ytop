-- File Name: sql_bind_by_sqlid.sql
-- Purpose: Expand SQL with binds then list v$sql_bind_capture rows
-- Created: 20260516  by  huangtingzhong
-- Updated: 20260809 by huangtingzhong (CLOB >32K; skip uncaptured; bind list)

--          from V$SQL_BIND_CAPTURE, ordered by POSITION.
-- Notes:
--   - sql_fulltext / literal rewrite use CLOB (UTF8 chunk=1000; no 32K cap).
--   - YashanDB may use '?' or ':name' placeholders in SQL_FULLTEXT.
--   - ':name' binds: find/splice outside quotes (SYS_B prefer :SYS_B_n).
--   - '?' binds use position-based replacement (see sql.sql / sql_pred).
--   - If V$SQL has no rows for the sql_id, print message and RETURN (no error).
--   - DATE/TIMESTAMP values are wrapped with to_date/to_timestamp (simple form).
--   - Literal: same child may have captured + uncaptured rows (e.g. empty VARCHAR +
--     filled CHAR); rewrite uses only last_captured IS NOT NULL AND value_string
--     IS NOT NULL; uncaptured positions stay as placeholders.
--   - Tail SELECT: all v$sql_bind_capture rows (no capture filter).
-- Usage:
--   ytop -f sql_bind_by_sqlid.sql   (prompt: &&sqlid)
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  c_sqlid           CONSTANT VARCHAR2(64) := '&&sqlid';
  c_chunk           CONSTANT PLS_INTEGER := 1000;

  lvc_sql_text      CLOB;
  lvc_orig_sql_text CLOB;
  ln_child          NUMBER;
  lvc_repl          VARCHAR2(4000);
  lvc_bind          VARCHAR2(200);
  lvc_name          VARCHAR2(128);
  ln_sql_len        NUMBER := 0;

  ln_bind_count     NUMBER := 0;
  ln_sql_cnt        NUMBER := 0;
  ln_qpos           NUMBER;
  ln_filled         NUMBER := 0;

  TYPE t_pos_seen IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
  v_pos_seen        t_pos_seen;

  -- Literal rewrite only: exclude uncaptured (same child may mix empty + filled)
  CURSOR c1(p_child NUMBER) IS
    SELECT child_number,
           name,
           position,
           datatype_string,
           value_string,
           sql_id
      FROM v$sql_bind_capture
     WHERE sql_id = c_sqlid
       AND child_number = p_child
       AND last_captured IS NOT NULL
       AND value_string IS NOT NULL
     ORDER BY last_captured DESC NULLS LAST,
              CASE WHEN name IS NOT NULL AND TRIM(name) <> '?' THEN 0 ELSE 1 END,
              position;

  FUNCTION clob_char(p_clob IN CLOB, p_pos IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_pos < 1 OR p_pos > NVL(DBMS_LOB.GETLENGTH(p_clob), 0) THEN
      RETURN NULL;
    END IF;
    RETURN DBMS_LOB.SUBSTR(p_clob, 1, p_pos);
  END;

  FUNCTION is_ident_char(p_ch IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    IF p_ch IS NULL THEN
      RETURN FALSE;
    END IF;
    RETURN (p_ch >= '0' AND p_ch <= '9')
        OR (UPPER(p_ch) >= 'A' AND UPPER(p_ch) <= 'Z')
        OR p_ch = '_';
  END;

  FUNCTION bind_pattern(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    v_bare VARCHAR2(128);
  BEGIN
    IF p_name IS NULL OR LENGTH(TRIM(p_name)) = 0 OR TRIM(p_name) = '?' THEN
      RETURN NULL;
    END IF;
    IF UPPER(LTRIM(p_name, ':')) LIKE 'SYS_B_%'
       OR UPPER(REPLACE(LTRIM(p_name, ':'), '"', '')) LIKE 'SYS_B_%' THEN
      v_bare := REPLACE(LTRIM(p_name, ':'), '"', '');
      RETURN ':' || v_bare;
    ELSIF p_name LIKE ':%' THEN
      RETURN p_name;
    ELSE
      RETURN ':' || LTRIM(p_name, ':');
    END IF;
  END;

  FUNCTION bind_pattern_alt(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    v_bare VARCHAR2(128);
  BEGIN
    IF p_name IS NULL OR LENGTH(TRIM(p_name)) = 0 OR TRIM(p_name) = '?' THEN
      RETURN NULL;
    END IF;
    IF UPPER(REPLACE(LTRIM(p_name, ':'), '"', '')) LIKE 'SYS_B_%' THEN
      v_bare := REPLACE(LTRIM(p_name, ':'), '"', '');
      RETURN ':"' || v_bare || '"';
    END IF;
    RETURN NULL;
  END;

  FUNCTION uses_question_bind_clob(p_clob IN CLOB) RETURN BOOLEAN IS
    v_p   NUMBER := 1;
    v_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    v_inq BOOLEAN := FALSE;
    v_ch  VARCHAR2(8);
  BEGIN
    WHILE v_p <= v_len LOOP
      v_ch := clob_char(p_clob, v_p);
      IF v_ch = '''' THEN
        IF v_inq AND v_p < v_len AND clob_char(p_clob, v_p + 1) = '''' THEN
          v_p := v_p + 2;
        ELSE
          v_inq := NOT v_inq;
          v_p := v_p + 1;
        END IF;
      ELSIF NOT v_inq AND v_ch = '?' THEN
        RETURN TRUE;
      ELSE
        v_p := v_p + 1;
      END IF;
    END LOOP;
    RETURN FALSE;
  END;

  FUNCTION find_question_clob(p_clob IN CLOB) RETURN NUMBER IS
    v_p   NUMBER := 1;
    v_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    v_inq BOOLEAN := FALSE;
    v_ch  VARCHAR2(8);
  BEGIN
    WHILE v_p <= v_len LOOP
      v_ch := clob_char(p_clob, v_p);
      IF v_ch = '''' THEN
        IF v_inq AND v_p < v_len AND clob_char(p_clob, v_p + 1) = '''' THEN
          v_p := v_p + 2;
        ELSE
          v_inq := NOT v_inq;
          v_p := v_p + 1;
        END IF;
      ELSIF NOT v_inq AND v_ch = '?' THEN
        RETURN v_p;
      ELSE
        v_p := v_p + 1;
      END IF;
    END LOOP;
    RETURN 0;
  END;

  FUNCTION find_pattern_clob(p_clob IN CLOB, p_pattern IN VARCHAR2) RETURN NUMBER IS
    v_p    NUMBER := 1;
    v_len  NUMBER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    v_plen NUMBER := NVL(LENGTH(p_pattern), 0);
    v_inq  BOOLEAN := FALSE;
    v_ch   VARCHAR2(8);
    v_next VARCHAR2(8);
    v_frag VARCHAR2(4000);
  BEGIN
    IF v_plen = 0 OR v_plen > 4000 THEN
      RETURN 0;
    END IF;
    WHILE v_p <= v_len LOOP
      v_ch := clob_char(p_clob, v_p);
      IF v_ch = '''' THEN
        IF v_inq AND v_p < v_len AND clob_char(p_clob, v_p + 1) = '''' THEN
          v_p := v_p + 2;
        ELSE
          v_inq := NOT v_inq;
          v_p := v_p + 1;
        END IF;
      ELSIF NOT v_inq AND v_p + v_plen - 1 <= v_len THEN
        v_frag := DBMS_LOB.SUBSTR(p_clob, v_plen, v_p);
        IF UPPER(v_frag) = UPPER(p_pattern) THEN
          v_next := clob_char(p_clob, v_p + v_plen);
          IF p_pattern LIKE ':%' AND is_ident_char(v_next) THEN
            v_p := v_p + 1;
          ELSE
            RETURN v_p;
          END IF;
        ELSE
          v_p := v_p + 1;
        END IF;
      ELSE
        v_p := v_p + 1;
      END IF;
    END LOOP;
    RETURN 0;
  END;

  PROCEDURE clob_splice_replace(
    p_clob        IN OUT NOCOPY CLOB,
    p_start       IN NUMBER,
    p_match_len   IN NUMBER,
    p_replacement IN VARCHAR2
  ) IS
    v_new CLOB;
    v_len NUMBER;
    v_off NUMBER;
    v_amt NUMBER;
    v_buf VARCHAR2(4000);
  BEGIN
    v_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    DBMS_LOB.CREATETEMPORARY(v_new, TRUE);

    v_off := 1;
    WHILE v_off < p_start LOOP
      v_amt := LEAST(c_chunk, p_start - v_off);
      v_buf := DBMS_LOB.SUBSTR(p_clob, v_amt, v_off);
      DBMS_LOB.WRITEAPPEND(v_new, LENGTH(v_buf), v_buf);
      v_off := v_off + v_amt;
    END LOOP;

    IF p_replacement IS NOT NULL AND LENGTH(p_replacement) > 0 THEN
      DBMS_LOB.WRITEAPPEND(v_new, LENGTH(p_replacement), p_replacement);
    END IF;

    v_off := p_start + p_match_len;
    WHILE v_off <= v_len LOOP
      v_amt := LEAST(c_chunk, v_len - v_off + 1);
      v_buf := DBMS_LOB.SUBSTR(p_clob, v_amt, v_off);
      DBMS_LOB.WRITEAPPEND(v_new, LENGTH(v_buf), v_buf);
      v_off := v_off + v_amt;
    END LOOP;

    IF DBMS_LOB.ISTEMPORARY(p_clob) = 1 THEN
      DBMS_LOB.FREETEMPORARY(p_clob);
    END IF;
    p_clob := v_new;
  END;

  PROCEDURE put_clob(p_text IN CLOB) IS
    v_len NUMBER;
    v_off NUMBER := 1;
    v_buf VARCHAR2(4000);
  BEGIN
    IF p_text IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('');
      RETURN;
    END IF;
    v_len := NVL(DBMS_LOB.GETLENGTH(p_text), 0);
    IF v_len = 0 THEN
      DBMS_OUTPUT.PUT_LINE('');
      RETURN;
    END IF;
    WHILE v_off <= v_len LOOP
      v_buf := DBMS_LOB.SUBSTR(p_text, LEAST(c_chunk, v_len - v_off + 1), v_off);
      DBMS_OUTPUT.PUT_LINE(v_buf);
      v_off := v_off + c_chunk;
    END LOOP;
  END;

  PROCEDURE clob_copy_from(p_src IN CLOB, p_dst IN OUT NOCOPY CLOB) IS
  BEGIN
    IF p_dst IS NOT NULL AND DBMS_LOB.ISTEMPORARY(p_dst) = 1 THEN
      DBMS_LOB.FREETEMPORARY(p_dst);
    END IF;
    DBMS_LOB.CREATETEMPORARY(p_dst, TRUE);
    IF p_src IS NOT NULL AND NVL(DBMS_LOB.GETLENGTH(p_src), 0) > 0 THEN
      DBMS_LOB.APPEND(p_dst, p_src);
    END IF;
  END;

BEGIN
  SELECT COUNT(*)
    INTO ln_sql_cnt
    FROM v$sql
   WHERE sql_id = c_sqlid;

  IF ln_sql_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No SQL found in V$SQL for sql_id=' || c_sqlid);
    RETURN;
  END IF;

  -- Prefer child of latest last_captured bind (lightweight; no correlated COUNT)
  BEGIN
    SELECT child_number, 1
      INTO ln_child, ln_filled
      FROM (
             SELECT child_number
               FROM v$sql_bind_capture
              WHERE sql_id = c_sqlid
                AND last_captured IS NOT NULL
              ORDER BY last_captured DESC NULLS LAST, child_number
           )
     WHERE ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      ln_child := NULL;
      ln_filled := 0;
  END;

  IF ln_child IS NULL THEN
    DBMS_OUTPUT.PUT_LINE(
      'No captured binds (last_captured empty) for sql_id=' || c_sqlid
    );
    SELECT sql_fulltext, parsing_schema_name
      INTO lvc_orig_sql_text, lvc_name
      FROM (
             SELECT s.sql_fulltext, s.parsing_schema_name
               FROM v$sql s
              WHERE s.sql_id = c_sqlid
              ORDER BY s.last_active_time DESC NULLS LAST, s.child_number
           )
     WHERE ROWNUM = 1;
    DBMS_OUTPUT.PUT_LINE(
      'Schema: ' || lvc_name
      || ' chars=' || TO_CHAR(NVL(DBMS_LOB.GETLENGTH(lvc_orig_sql_text), 0))
    );
    put_clob(lvc_orig_sql_text);
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
    RETURN;
  END IF;

  BEGIN
    SELECT sql_fulltext, parsing_schema_name
      INTO lvc_orig_sql_text, lvc_name
      FROM v$sql
     WHERE sql_id = c_sqlid
       AND child_number = ln_child
       AND ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      SELECT sql_fulltext, parsing_schema_name
        INTO lvc_orig_sql_text, lvc_name
        FROM (
               SELECT s.sql_fulltext, s.parsing_schema_name
                 FROM v$sql s
                WHERE s.sql_id = c_sqlid
                ORDER BY s.last_active_time DESC NULLS LAST, s.child_number
             )
       WHERE ROWNUM = 1;
  END;

  ln_sql_len := NVL(DBMS_LOB.GETLENGTH(lvc_orig_sql_text), 0);

  SELECT COUNT(*)
    INTO ln_bind_count
    FROM v$sql_bind_capture
   WHERE sql_id = c_sqlid
     AND child_number = ln_child
     AND last_captured IS NOT NULL
     AND value_string IS NOT NULL
     AND ROWNUM = 1;

  IF ln_bind_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE(
      'Schema: ' || lvc_name || ' child=' || TO_CHAR(ln_child)
      || ' chars=' || TO_CHAR(ln_sql_len)
    );
    put_clob(lvc_orig_sql_text);
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
    RETURN;
  END IF;

  clob_copy_from(lvc_orig_sql_text, lvc_sql_text);
  DBMS_OUTPUT.PUT_LINE(
    'bind child=' || TO_CHAR(ln_child) || ' filled=' || TO_CHAR(ln_filled)
    || ' captured_rows=' || TO_CHAR(ln_bind_count)
    || ' chars=' || TO_CHAR(ln_sql_len)
  );
  v_pos_seen.DELETE;

  FOR r1 IN c1(ln_child) LOOP
    IF r1.value_string IS NOT NULL
       AND NOT v_pos_seen.EXISTS(r1.position) THEN
    v_pos_seen(r1.position) := 1;

    BEGIN
      SELECT parsing_schema_name
        INTO lvc_name
        FROM v$sql
       WHERE sql_id = r1.sql_id
         AND child_number = r1.child_number
         AND ROWNUM = 1;
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;

    IF r1.datatype_string = 'NUMBER' THEN
      lvc_repl := SUBSTR(r1.value_string, 1, 4000);
    ELSIF r1.datatype_string = 'DATE' THEN
      lvc_repl := 'to_date(''' || REPLACE(SUBSTR(r1.value_string, 1, 3900), '''', '''''') || ''')';
    ELSIF r1.datatype_string LIKE 'TIMESTAMP%' THEN
      lvc_repl := 'to_timestamp(''' || REPLACE(SUBSTR(r1.value_string, 1, 3900), '''', '''''') || ''')';
    ELSE
      lvc_repl := '''' || REPLACE(SUBSTR(r1.value_string, 1, 3900), '''', '''''') || '''';
    END IF;

    lvc_bind := bind_pattern(r1.name);

    IF lvc_bind IS NOT NULL AND NOT uses_question_bind_clob(lvc_orig_sql_text) THEN
      ln_qpos := find_pattern_clob(lvc_sql_text, lvc_bind);
      IF ln_qpos = 0 AND bind_pattern_alt(r1.name) IS NOT NULL THEN
        lvc_bind := bind_pattern_alt(r1.name);
        ln_qpos := find_pattern_clob(lvc_sql_text, lvc_bind);
      END IF;
      IF ln_qpos = 0 THEN
        ln_qpos := find_question_clob(lvc_sql_text);
        IF ln_qpos = 0 THEN
          DBMS_OUTPUT.PUT_LINE(
            'ERROR: bind pattern not found. ' ||
            'bind position=' || r1.position || ', name=' || NVL(r1.name, '(null)') ||
            ', pattern=' || NVL(bind_pattern(r1.name), '(null)')
          );
          RETURN;
        END IF;
        clob_splice_replace(lvc_sql_text, ln_qpos, 1, lvc_repl);
      ELSE
        clob_splice_replace(lvc_sql_text, ln_qpos, LENGTH(lvc_bind), lvc_repl);
      END IF;
    ELSE
      ln_qpos := find_question_clob(lvc_sql_text);
      IF ln_qpos = 0 THEN
        DBMS_OUTPUT.PUT_LINE(
          'ERROR: no remaining ''?'' placeholders while replacing binds. ' ||
          'bind position=' || r1.position || ', name=' || NVL(r1.name, '(null)')
        );
        RETURN;
      END IF;
      clob_splice_replace(lvc_sql_text, ln_qpos, 1, lvc_repl);
    END IF;
    END IF; -- position dedupe
  END LOOP;

  DBMS_OUTPUT.PUT_LINE(
    'Schema: ' || lvc_name
    || ' chars=' || TO_CHAR(NVL(DBMS_LOB.GETLENGTH(lvc_sql_text), 0))
  );
  put_clob(lvc_sql_text);
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
END;
/

-- Manual bind capture listing (all rows; may show empty VARCHAR + filled CHAR per pos)
PROMPT
PROMPT ****************************************************************************************
PROMPT BIND CAPTURE from v$sql_bind_capture
PROMPT ****************************************************************************************
PROMPT

-- width budget: 6+4+40+16+64 + 4 spaces ~= 134 (<=200); list ALL rows (no capture filter)
col child# for a6
col pos    for a4
col name   for a40
col dtype  for a16
col value  for a64

SELECT TO_CHAR(child_number) AS child#,
       TO_CHAR(position) AS pos,
       name,
       datatype_string AS dtype,
       SUBSTR(value_string, 1, 64) AS value
  FROM v$sql_bind_capture
 WHERE sql_id = '&&sqlid'
 ORDER BY child_number, position, datatype_string
/
