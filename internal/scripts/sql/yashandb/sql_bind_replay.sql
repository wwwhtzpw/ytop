-- File Name: sql_bind_replay.sql
-- Purpose: Business-sim replay by sql_id (orig text+binds+schema; print/explain/execute)
-- Created: 20260802 by huangtingzhong
-- Updated: 20260805 by huangtingzhong (exclude last_captured empty; prefer filled child)
--
-- Mode C: generate typed variables + EXECUTE IMMEDIATE ... USING (paste).
-- action=print|explain: print paste block only (:B001 rewrite for USING convenience).
-- action=execute + confirm=YES: business-like run:
--   * original v$sql.sql_fulltext (no :B001 rewrite for named binds)
--   * DBMS_SQL.BIND_VARIABLE with original capture bind names
--   * ALTER SESSION CURRENT_SCHEMA = parsing_schema (or override); restore after
-- show_rows default NO; YES prints up to max_rows.
-- Long SQL / binds / show_rows use DBMS_SQL (bypass EXECUTE IMMEDIATE ~64K).
-- Do NOT use paste output as SQLMAP source SQL (:B001 rewrite changes hash).
-- Notes:
--   - Binds from V$SQL_BIND_CAPTURE; empty child => child with most captured values
--     (last_captured IS NOT NULL or WAS_CAPTURED=YES; exclude empty slots).
--   - Paste block still rewrites to :B001.. for USING; execute does NOT (named binds).
--   - "?" placeholders: execute must rewrite to :Bnnn (DBMS_SQL); may miss SQLMAP.
--   - No capture + no placeholder => direct execute of sql_fulltext.
--   - No capture + placeholder => refuse execute (print only).

SET SERVEROUTPUT ON


ACCEPT sqlid PROMPT 'Enter sql_id (required): '
ACCEPT child PROMPT 'Enter child_number (empty=prefer captured binds): '
ACCEPT action PROMPT 'Enter action (print|explain|execute, default print): '
ACCEPT confirm PROMPT 'Confirm execute (YES=run; other/Enter=abort; ignored unless action=execute): '
ACCEPT schema PROMPT 'Enter CURRENT_SCHEMA override (empty=parsing_schema_name): '
ACCEPT show_rows PROMPT 'Print result rows (YES/NO, default NO): '
ACCEPT max_rows PROMPT 'Max rows to print (default 20; ignored unless show_rows=YES): '

DECLARE
  c_err_no_sql    CONSTANT NUMBER := 30301;
  c_err_bad_act   CONSTANT NUMBER := 30302;
  c_err_rewrite   CONSTANT NUMBER := 30303;
  c_err_no_bind   CONSTANT NUMBER := 30304;
  -- UTF8 多字节时 SUBSTR(字符) 写入 VARCHAR2(4000) 可能超字节上限, 故用 1000
  c_chunk         CONSTANT PLS_INTEGER := 1000;
  -- below this: generated block uses VARCHAR2; at/above: CLOB + WRITEAPPEND
  -- 含中文时字面量拼接易触字节上限, 长 SQL 优先走 CLOB
  c_varchar_limit CONSTANT PLS_INTEGER := 8000;
  -- emit 分片: 按字符 SUBSTR 时预留 UTF8 字节余量
  c_emit_chunk    CONSTANT PLS_INTEGER := 300;
  -- EXECUTE IMMEDIATE 安全阈值(字符); 超过走 DBMS_SQL.PARSE(CLOB)
  c_ei_safe       CONSTANT PLS_INTEGER := 60000;
  c_col_val_len   CONSTANT PLS_INTEGER := 4000;
  c_default_max_rows CONSTANT PLS_INTEGER := 20;

  v_sqlid         VARCHAR2(64) := TRIM('&&sqlid');
  v_child_in      VARCHAR2(32) := TRIM('&&child');
  v_action        VARCHAR2(16) := LOWER(NVL(NULLIF(TRIM('&&action'), ''), 'print'));
  v_confirm       VARCHAR2(32) := TRIM('&&confirm');
  v_schema_in     VARCHAR2(128) := TRIM('&&schema');
  v_show_rows_in  VARCHAR2(16) := UPPER(TRIM('&&show_rows'));
  v_max_rows_in   VARCHAR2(32) := TRIM('&&max_rows');
  v_show_rows     BOOLEAN;
  v_max_rows      PLS_INTEGER;
  v_child         NUMBER;
  v_exec_block    CLOB;
  v_sql_cnt       NUMBER;
  v_bind_cnt      NUMBER;
  v_schema        VARCHAR2(128);
  v_schema_target VARCHAR2(128);
  v_schema_prev   VARCHAR2(128);
  v_schema_switched BOOLEAN := FALSE;
  v_sql_clob      CLOB;
  v_replay_clob   CLOB;
  v_run_clob      CLOB;
  v_sql_len       NUMBER;
  v_use_clob_gen  BOOLEAN;
  v_ph_type       VARCHAR2(32);
  v_has_ph        BOOLEAN;
  v_decl          VARCHAR2(32767);
  v_assign        VARCHAR2(32767);
  v_using         VARCHAR2(4000);
  v_line          VARCHAR2(4000);
  v_var           VARCHAR2(30);
  v_dtype         VARCHAR2(64);
  v_assign_expr   VARCHAR2(4000);
  v_maxlen        NUMBER;
  v_warn          VARCHAR2(16);
  v_idx           PLS_INTEGER := 0;
  TYPE t_pos_seen IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
  v_pos_seen      t_pos_seen;
  v_qpos          NUMBER;
  v_bind_pat      VARCHAR2(200);
  v_repl          VARCHAR2(16);
  v_cur           INTEGER;
  v_ret           INTEGER;
  v_num           NUMBER;
  v_date          DATE;
  v_ts            TIMESTAMP;
  v_str           VARCHAR2(4000);

  TYPE t_bind IS RECORD (
    bname   VARCHAR2(30),
    ds      VARCHAR2(64),
    val_str VARCHAR2(4000)
  );
  TYPE t_bind_tab IS TABLE OF t_bind INDEX BY PLS_INTEGER;
  v_bind_tab t_bind_tab;

  CURSOR c_binds(p_sqlid VARCHAR2, p_child NUMBER) IS
    SELECT position,
           name,
           datatype_string,
           value_string,
           was_captured,
           max_length
      FROM v$sql_bind_capture
     WHERE sql_id = p_sqlid
       AND child_number = p_child
       AND last_captured IS NOT NULL
     ORDER BY last_captured DESC NULLS LAST,
              CASE WHEN name IS NOT NULL AND TRIM(name) <> '?' THEN 0 ELSE 1 END,
              position;

  PROCEDURE put_clob(p_text IN CLOB) IS
    v_len NUMBER;
    v_off NUMBER := 1;
    v_buf VARCHAR2(4000);
  BEGIN
    IF p_text IS NULL THEN
      RETURN;
    END IF;
    v_len := NVL(DBMS_LOB.GETLENGTH(p_text), 0);
    WHILE v_off <= v_len LOOP
      v_buf := DBMS_LOB.SUBSTR(p_text, LEAST(c_chunk, v_len - v_off + 1), v_off);
      DBMS_OUTPUT.PUT_LINE(v_buf);
      v_off := v_off + c_chunk;
    END LOOP;
  END;

  PROCEDURE put_varchar(p_text IN VARCHAR2) IS
    v_len PLS_INTEGER;
    v_off PLS_INTEGER := 1;
  BEGIN
    IF p_text IS NULL THEN
      RETURN;
    END IF;
    v_len := NVL(LENGTH(p_text), 0);
    WHILE v_off <= v_len LOOP
      DBMS_OUTPUT.PUT_LINE(SUBSTR(p_text, v_off, c_chunk));
      v_off := v_off + c_chunk;
    END LOOP;
  END;

  -- 单字符缓冲用 VARCHAR2(8): UTF8 中文等不能塞进 VARCHAR2(1)(字节语义会 YAS-04412)
  FUNCTION clob_char(p_clob IN CLOB, p_pos IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_pos < 1 OR p_pos > NVL(DBMS_LOB.GETLENGTH(p_clob), 0) THEN
      RETURN NULL;
    END IF;
    RETURN DBMS_LOB.SUBSTR(p_clob, 1, p_pos);
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

  FUNCTION bind_pattern(p_name IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_name LIKE ':SYS_B_%' THEN
      RETURN ':"' || SUBSTR(p_name, 2) || '"';
    ELSIF p_name LIKE ':%' THEN
      RETURN p_name;
    ELSIF p_name IS NOT NULL AND LENGTH(TRIM(p_name)) > 0 THEN
      RETURN ':' || LTRIM(p_name, ':');
    ELSE
      RETURN NULL;
    END IF;
  END;

  -- DBMS_SQL.BIND_VARIABLE name: strip leading colon (:x -> x, :SYS_B_0 -> SYS_B_0)
  FUNCTION bind_var_name(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(128) := TRIM(p_name);
  BEGIN
    IF v IS NULL OR LENGTH(v) = 0 THEN
      RETURN NULL;
    END IF;
    IF SUBSTR(v, 1, 1) = ':' THEN
      RETURN SUBSTR(v, 2);
    END IF;
    RETURN v;
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

  FUNCTION uses_named_bind_clob(p_clob IN CLOB) RETURN BOOLEAN IS
    v_p   NUMBER := 1;
    v_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    v_inq BOOLEAN := FALSE;
    v_ch  VARCHAR2(8);
    v_nx  VARCHAR2(8);
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
      ELSIF NOT v_inq AND v_ch = ':' THEN
        v_nx := clob_char(p_clob, v_p + 1);
        IF v_nx = '"' OR is_ident_char(v_nx) THEN
          RETURN TRUE;
        END IF;
        v_p := v_p + 1;
      ELSE
        v_p := v_p + 1;
      END IF;
    END LOOP;
    RETURN FALSE;
  END;


  -- Find first '?' outside quotes; return 1-based offset or 0
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

  -- Find first named bind pattern outside quotes; return 1-based offset or 0
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

  FUNCTION sql_string_literal(p_text IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN '''' || REPLACE(p_text, '''', '''''') || '''';
  END;

  FUNCTION plsql_type(p_ds IN VARCHAR2, p_maxlen IN NUMBER) RETURN VARCHAR2 IS
    v_ds VARCHAR2(64) := UPPER(NVL(p_ds, 'VARCHAR'));
  BEGIN
    IF v_ds = 'NUMBER' OR v_ds LIKE 'NUMBER%' THEN
      RETURN 'NUMBER';
    ELSIF v_ds = 'DATE' THEN
      RETURN 'DATE';
    ELSIF v_ds LIKE 'TIMESTAMP%' THEN
      RETURN 'TIMESTAMP';
    ELSE
      RETURN 'VARCHAR2(' || TO_CHAR(LEAST(GREATEST(NVL(p_maxlen, 4000), 1), 4000)) || ')';
    END IF;
  END;

  FUNCTION assign_expr(p_ds IN VARCHAR2, p_val IN VARCHAR2) RETURN VARCHAR2 IS
    v_ds VARCHAR2(64) := UPPER(NVL(p_ds, 'VARCHAR'));
  BEGIN
    IF p_val IS NULL THEN
      RETURN 'NULL';
    ELSIF v_ds = 'NUMBER' OR v_ds LIKE 'NUMBER%' THEN
      IF TRIM(p_val) IS NULL THEN
        RETURN 'NULL';
      END IF;
      RETURN TRIM(p_val);
    ELSIF v_ds = 'DATE' THEN
      RETURN 'TO_DATE(' || sql_string_literal(p_val) || ')';
    ELSIF v_ds LIKE 'TIMESTAMP%' THEN
      RETURN 'TO_TIMESTAMP(' || sql_string_literal(p_val) || ')';
    ELSE
      RETURN sql_string_literal(p_val);
    END IF;
  END;

  PROCEDURE out_line(p_text IN VARCHAR2) IS
    v_t VARCHAR2(32767) := NVL(p_text, '');
  BEGIN
    DBMS_OUTPUT.PUT_LINE(v_t);
    IF v_exec_block IS NULL THEN
      DBMS_LOB.CREATETEMPORARY(v_exec_block, TRUE);
    END IF;
    IF LENGTH(v_t) > 0 THEN
      DBMS_LOB.WRITEAPPEND(v_exec_block, LENGTH(v_t), v_t);
    END IF;
    DBMS_LOB.WRITEAPPEND(v_exec_block, 1, CHR(10));
  END;

  PROCEDURE out_varchar_chunked(p_text IN VARCHAR2) IS
    v_len PLS_INTEGER;
    v_off PLS_INTEGER := 1;
  BEGIN
    IF p_text IS NULL THEN
      RETURN;
    END IF;
    v_len := NVL(LENGTH(p_text), 0);
    WHILE v_off <= v_len LOOP
      out_line(SUBSTR(p_text, v_off, c_chunk));
      v_off := v_off + c_chunk;
    END LOOP;
  END;

  PROCEDURE emit_sql_assign_varchar2(p_clob IN CLOB) IS
    v_off NUMBER := 1;
    v_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    v_buf VARCHAR2(4000);
    v_amt NUMBER;
    v_first BOOLEAN := TRUE;
  BEGIN
    out_line('  v_sql :=');
    IF v_len = 0 THEN
      out_line('    '''';');
      RETURN;
    END IF;
    WHILE v_off <= v_len LOOP
      v_amt := LEAST(c_emit_chunk, v_len - v_off + 1);
      v_buf := DBMS_LOB.SUBSTR(p_clob, v_amt, v_off);
      IF v_first THEN
        out_line('    ' || sql_string_literal(v_buf));
        v_first := FALSE;
      ELSE
        out_line('    || ' || sql_string_literal(v_buf));
      END IF;
      v_off := v_off + v_amt;
    END LOOP;
    out_line('    ;');
  END;

  PROCEDURE emit_sql_assign_clob(p_clob IN CLOB) IS
    v_off NUMBER := 1;
    v_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
    v_buf VARCHAR2(4000);
    v_amt NUMBER;
  BEGIN
    out_line('  DBMS_LOB.CREATETEMPORARY(v_sql, TRUE);');
    IF v_len = 0 THEN
      RETURN;
    END IF;
    WHILE v_off <= v_len LOOP
      v_amt := LEAST(c_emit_chunk, v_len - v_off + 1);
      v_buf := DBMS_LOB.SUBSTR(p_clob, v_amt, v_off);
      out_line(
        '  DBMS_LOB.WRITEAPPEND(v_sql, LENGTH(' || sql_string_literal(v_buf)
        || '), ' || sql_string_literal(v_buf) || ');');
      v_off := v_off + v_amt;
    END LOOP;
  END;

  FUNCTION schema_ident(p_schema IN VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(128) := TRIM(p_schema);
  BEGIN
    IF v IS NULL THEN
      RETURN NULL;
    END IF;
    IF REGEXP_LIKE(v, '^[A-Za-z][A-Za-z0-9_#$]*$') THEN
      RETURN UPPER(v);
    END IF;
    RETURN '"' || REPLACE(v, '"', '""') || '"';
  END;

  PROCEDURE switch_schema(p_target IN VARCHAR2) IS
    v_id VARCHAR2(256);
  BEGIN
    SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') INTO v_schema_prev FROM DUAL;
    IF p_target IS NULL OR LENGTH(TRIM(p_target)) = 0 THEN
      DBMS_OUTPUT.PUT_LINE('-- CURRENT_SCHEMA skip: target empty; stay='
        || NVL(v_schema_prev, '?'));
      RETURN;
    END IF;
    v_id := schema_ident(p_target);
    IF UPPER(NVL(v_schema_prev, '@')) = UPPER(TRIM(p_target)) THEN
      DBMS_OUTPUT.PUT_LINE('-- CURRENT_SCHEMA already=' || NVL(v_schema_prev, '?'));
      RETURN;
    END IF;
    EXECUTE IMMEDIATE 'ALTER SESSION SET CURRENT_SCHEMA = ' || v_id;
    v_schema_switched := TRUE;
    DBMS_OUTPUT.PUT_LINE('-- CURRENT_SCHEMA ' || NVL(v_schema_prev, '?')
      || ' -> ' || v_id);
  END;

  PROCEDURE restore_schema IS
    v_id VARCHAR2(256);
  BEGIN
    IF NOT v_schema_switched THEN
      RETURN;
    END IF;
    IF v_schema_prev IS NULL THEN
      RETURN;
    END IF;
    v_id := schema_ident(v_schema_prev);
    BEGIN
      EXECUTE IMMEDIATE 'ALTER SESSION SET CURRENT_SCHEMA = ' || v_id;
      DBMS_OUTPUT.PUT_LINE('-- CURRENT_SCHEMA restored -> ' || v_id);
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('-- CURRENT_SCHEMA restore FAILED: ' || SQLERRM);
    END;
    v_schema_switched := FALSE;
  END;

  PROCEDURE bind_one(p_cur IN INTEGER, p_bname IN VARCHAR2,
                     p_ds IN VARCHAR2, p_val IN VARCHAR2) IS
    v_d VARCHAR2(64) := UPPER(NVL(p_ds, 'VARCHAR'));
  BEGIN
    IF p_val IS NULL THEN
      IF v_d = 'NUMBER' OR v_d LIKE 'NUMBER%' THEN
        v_num := NULL;
        DBMS_SQL.BIND_VARIABLE(p_cur, p_bname, v_num);
      ELSIF v_d = 'DATE' THEN
        v_date := NULL;
        DBMS_SQL.BIND_VARIABLE(p_cur, p_bname, v_date);
      ELSIF v_d LIKE 'TIMESTAMP%' THEN
        v_ts := NULL;
        DBMS_SQL.BIND_VARIABLE(p_cur, p_bname, v_ts);
      ELSE
        v_str := NULL;
        DBMS_SQL.BIND_VARIABLE(p_cur, p_bname, v_str);
      END IF;
      RETURN;
    END IF;
    IF v_d = 'NUMBER' OR v_d LIKE 'NUMBER%' THEN
      IF TRIM(p_val) IS NULL THEN
        v_num := NULL;
      ELSE
        v_num := TO_NUMBER(TRIM(p_val));
      END IF;
      DBMS_SQL.BIND_VARIABLE(p_cur, p_bname, v_num);
    ELSIF v_d = 'DATE' THEN
      v_date := TO_DATE(p_val);
      DBMS_SQL.BIND_VARIABLE(p_cur, p_bname, v_date);
    ELSIF v_d LIKE 'TIMESTAMP%' THEN
      v_ts := TO_TIMESTAMP(p_val);
      DBMS_SQL.BIND_VARIABLE(p_cur, p_bname, v_ts);
    ELSE
      v_str := p_val;
      DBMS_SQL.BIND_VARIABLE(p_cur, p_bname, v_str);
    END IF;
  END;

  PROCEDURE run_sql_clob(p_sql IN CLOB, p_explain IN BOOLEAN) IS
    v_len       NUMBER := NVL(DBMS_LOB.GETLENGTH(p_sql), 0);
    v_need_dbms BOOLEAN;
    v_col_cnt   INTEGER;
    v_desc      DBMS_SQL.DESC_TAB;
    v_col_val   VARCHAR2(4000);
    v_row_num   PLS_INTEGER := 0;
    v_name_w    PLS_INTEGER := 0;
    v_i         PLS_INTEGER;
    v_can_fetch BOOLEAN := FALSE;
  BEGIN
    IF p_explain THEN
      DBMS_LOB.CREATETEMPORARY(v_run_clob, TRUE);
      DBMS_LOB.WRITEAPPEND(v_run_clob, 8, 'EXPLAIN ');
      IF v_len > 0 THEN
        DBMS_LOB.APPEND(v_run_clob, p_sql);
      END IF;
    ELSE
      v_run_clob := p_sql;
    END IF;

    v_len := NVL(DBMS_LOB.GETLENGTH(v_run_clob), 0);
    -- 长 SQL / 有绑定 / 要打结果集: 统一 DBMS_SQL (EI 约 64K; 结果集需 DESCRIBE+FETCH)
    v_need_dbms := FALSE;
    IF v_show_rows THEN
      v_need_dbms := TRUE;
    ELSIF v_bind_tab.COUNT > 0 THEN
      v_need_dbms := TRUE;
    ELSIF v_len >= c_ei_safe THEN
      v_need_dbms := TRUE;
    ELSIF p_explain THEN
      v_need_dbms := TRUE;
    END IF;

    IF NOT v_need_dbms THEN
      EXECUTE IMMEDIATE v_run_clob;
      DBMS_OUTPUT.PUT_LINE('-- execute path=EXECUTE_IMMEDIATE chars='
        || TO_CHAR(v_len) || ' SQL%ROWCOUNT=' || TO_CHAR(SQL%ROWCOUNT)
        || ' show_rows=NO');
      RETURN;
    END IF;

    v_cur := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(v_cur, v_run_clob, 1);
    IF v_bind_tab.COUNT > 0 THEN
      FOR i IN 1 .. v_bind_tab.COUNT LOOP
        bind_one(v_cur, v_bind_tab(i).bname, v_bind_tab(i).ds, v_bind_tab(i).val_str);
      END LOOP;
    END IF;

    IF v_show_rows AND NOT p_explain THEN
      BEGIN
        DBMS_SQL.DESCRIBE_COLUMNS(v_cur, v_col_cnt, v_desc);
        IF v_col_cnt > 0 THEN
          v_can_fetch := TRUE;
          FOR v_i IN 1 .. v_col_cnt LOOP
            IF LENGTH(v_desc(v_i).col_name) > v_name_w THEN
              v_name_w := LENGTH(v_desc(v_i).col_name);
            END IF;
          END LOOP;
          FOR v_i IN 1 .. v_col_cnt LOOP
            -- 113=BLOB: skip define; print marker on fetch
            IF v_desc(v_i).col_type = 113 THEN
              NULL;
            ELSE
              DBMS_SQL.DEFINE_COLUMN(v_cur, v_i, v_col_val, c_col_val_len);
            END IF;
          END LOOP;
        END IF;
      EXCEPTION
        WHEN OTHERS THEN
          -- DML/DDL or non-query: fall through to execute-only
          v_can_fetch := FALSE;
          DBMS_OUTPUT.PUT_LINE(
            '-- show_rows requested but DESCRIBE failed (likely non-query): '
            || SQLERRM);
      END;
    END IF;

    v_ret := DBMS_SQL.EXECUTE(v_cur);

    IF v_can_fetch THEN
      DBMS_OUTPUT.PUT_LINE('-- ----- result rows (max=' || TO_CHAR(v_max_rows)
        || '; col_val truncated at ' || TO_CHAR(c_col_val_len) || ' chars) -----');
      WHILE DBMS_SQL.FETCH_ROWS(v_cur) > 0 LOOP
        v_row_num := v_row_num + 1;
        IF v_row_num > v_max_rows THEN
          DBMS_OUTPUT.PUT_LINE('-- ... truncated at max_rows=' || TO_CHAR(v_max_rows));
          EXIT;
        END IF;
        DBMS_OUTPUT.PUT_LINE('=====row' || TO_CHAR(v_row_num) || '=====');
        FOR v_i IN 1 .. v_col_cnt LOOP
          IF v_desc(v_i).col_type = 113 THEN
            DBMS_OUTPUT.PUT_LINE(
              RPAD(v_desc(v_i).col_name, v_name_w) || '=<BLOB>');
          ELSE
            DBMS_SQL.COLUMN_VALUE(v_cur, v_i, v_col_val);
            DBMS_OUTPUT.PUT_LINE(
              RPAD(v_desc(v_i).col_name, v_name_w) || '='
              || NVL(v_col_val, '(null)'));
          END IF;
        END LOOP;
      END LOOP;
      IF v_row_num = 0 THEN
        DBMS_OUTPUT.PUT_LINE('(no rows)');
      ELSIF v_row_num > v_max_rows THEN
        NULL; -- already noted truncation
      END IF;
      DBMS_OUTPUT.PUT_LINE('-- ----- end result rows (printed='
        || TO_CHAR(LEAST(v_row_num, v_max_rows)) || ') -----');
    END IF;

    DBMS_SQL.CLOSE_CURSOR(v_cur);
    DBMS_OUTPUT.PUT_LINE('-- execute path=DBMS_SQL chars=' || TO_CHAR(v_len)
      || ' ret=' || TO_CHAR(v_ret)
      || ' show_rows=' || CASE WHEN v_show_rows THEN 'YES' ELSE 'NO' END
      || CASE WHEN v_can_fetch THEN ' fetched' ELSE '' END);
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        IF v_cur IS NOT NULL AND DBMS_SQL.IS_OPEN(v_cur) THEN
          DBMS_SQL.CLOSE_CURSOR(v_cur);
        END IF;
      EXCEPTION
        WHEN OTHERS THEN
          NULL;
      END;
      RAISE;
  END;

  PROCEDURE do_execute(p_sql IN CLOB, p_explain IN BOOLEAN) IS
  BEGIN
    IF UPPER(NVL(TRIM(v_confirm), 'NO')) <> 'YES' THEN
      DBMS_OUTPUT.PUT_LINE(
        '-- execute aborted: confirm must be YES (got: '
        || NVL(v_confirm, '<empty>') || ')');
      RETURN;
    END IF;
    DBMS_OUTPUT.PUT_LINE(
      '-- executing BUSINESS-SIM ... original sql_fulltext + original bind names'
      || ' show_rows='
      || CASE WHEN v_show_rows THEN 'YES max_rows=' || TO_CHAR(v_max_rows) ELSE 'NO' END);
    switch_schema(v_schema_target);
    BEGIN
      run_sql_clob(p_sql, p_explain);
      DBMS_OUTPUT.PUT_LINE('-- execute finished OK');
      restore_schema;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('-- execute FAILED: ' || SQLERRM);
        restore_schema;
        RAISE;
    END;
  END;

BEGIN
  DBMS_OUTPUT.ENABLE(10000000);

  v_show_rows := FALSE;
  IF v_show_rows_in IN ('YES', 'Y', '1', 'TRUE', 'ON') THEN
    v_show_rows := TRUE;
  END IF;
  IF NULLIF(v_max_rows_in, '') IS NULL THEN
    v_max_rows := c_default_max_rows;
  ELSE
    BEGIN
      v_max_rows := GREATEST(TO_NUMBER(v_max_rows_in), 1);
    EXCEPTION
      WHEN OTHERS THEN
        v_max_rows := c_default_max_rows;
    END;
  END IF;

  IF v_sqlid IS NULL OR LENGTH(v_sqlid) = 0 THEN
    RAISE_APPLICATION_ERROR(c_err_no_sql, 'sql_id is required');
  END IF;

  IF v_action NOT IN ('print', 'explain', 'execute') THEN
    RAISE_APPLICATION_ERROR(c_err_bad_act,
      'action must be print, explain or execute, got: ' || v_action);
  END IF;

  SELECT COUNT(*) INTO v_sql_cnt FROM v$sql WHERE sql_id = v_sqlid;
  IF v_sql_cnt = 0 THEN
    RAISE_APPLICATION_ERROR(c_err_no_sql,
      'sql_id not found in v$sql: ' || v_sqlid);
  END IF;

  IF NULLIF(v_child_in, '') IS NULL THEN
    -- Prefer child of latest last_captured bind (lightweight)
    BEGIN
      SELECT child_number
        INTO v_child
        FROM (
               SELECT child_number
                 FROM v$sql_bind_capture
                WHERE sql_id = v_sqlid
                  AND last_captured IS NOT NULL
                ORDER BY last_captured DESC NULLS LAST, child_number
             )
       WHERE ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_child := NULL;
    END;
    IF v_child IS NULL THEN
      SELECT MIN(child_number) INTO v_child FROM v$sql WHERE sql_id = v_sqlid;
    END IF;
  ELSE
    v_child := TO_NUMBER(v_child_in);
  END IF;

  BEGIN
    SELECT sql_fulltext, parsing_schema_name
      INTO v_sql_clob, v_schema
      FROM v$sql
     WHERE sql_id = v_sqlid
       AND child_number = v_child
       AND ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      SELECT sql_fulltext, parsing_schema_name
        INTO v_sql_clob, v_schema
        FROM v$sql
       WHERE sql_id = v_sqlid
         AND ROWNUM = 1;
  END;

  IF NULLIF(v_schema_in, '') IS NOT NULL THEN
    v_schema_target := v_schema_in;
  ELSE
    v_schema_target := v_schema;
  END IF;

  v_sql_len := NVL(DBMS_LOB.GETLENGTH(v_sql_clob), 0);
  v_use_clob_gen := (v_sql_len >= c_varchar_limit);

  SELECT COUNT(*)
    INTO v_bind_cnt
    FROM v$sql_bind_capture
   WHERE sql_id = v_sqlid
     AND child_number = v_child
     AND last_captured IS NOT NULL
     AND ROWNUM = 1;

  IF uses_question_bind_clob(v_sql_clob) THEN
    v_ph_type := 'question_mark';
    v_has_ph := TRUE;
  ELSIF uses_named_bind_clob(v_sql_clob) THEN
    v_ph_type := 'named';
    v_has_ph := TRUE;
  ELSE
    v_ph_type := 'none';
    v_has_ph := FALSE;
  END IF;

  DBMS_OUTPUT.PUT_LINE('-- ============================================================');
  DBMS_OUTPUT.PUT_LINE('-- sql_bind_replay (print/explain=paste; execute needs YES)');
  DBMS_OUTPUT.PUT_LINE('-- sql_id=' || v_sqlid || ' child=' || TO_CHAR(v_child)
    || ' action=' || v_action);
  DBMS_OUTPUT.PUT_LINE('-- parsing_schema=' || NVL(v_schema, '-')
    || ' current_schema_target=' || NVL(v_schema_target, '-'));
  DBMS_OUTPUT.PUT_LINE('-- bind_count=' || TO_CHAR(v_bind_cnt)
    || ' placeholder_type=' || v_ph_type);
  DBMS_OUTPUT.PUT_LINE('-- sql_fulltext_chars=' || TO_CHAR(v_sql_len)
    || ' gen_mode=' || CASE WHEN v_use_clob_gen THEN 'CLOB' ELSE 'VARCHAR2' END
    || ' ei_safe=' || TO_CHAR(c_ei_safe));
  DBMS_OUTPUT.PUT_LINE('-- show_rows='
    || CASE WHEN v_show_rows THEN 'YES' ELSE 'NO' END
    || ' max_rows=' || TO_CHAR(v_max_rows)
    || ' (result print only when show_rows=YES on execute)');
  DBMS_OUTPUT.PUT_LINE('-- NOTE: do NOT use paste output as SQLMAP source SQL text');
  DBMS_OUTPUT.PUT_LINE('-- NOTE: execute=business-sim (orig text+bind names); paste uses :Bnnn');
  DBMS_OUTPUT.PUT_LINE('-- NOTE: long SQL / binds / show_rows use DBMS_SQL path');
  IF v_bind_cnt > 0 THEN
    DBMS_OUTPUT.PUT_LINE(
      '-- NOTE: paste block only rewrites to :B001..; execute keeps original names');
  END IF;
  IF v_action = 'execute' THEN
    DBMS_OUTPUT.PUT_LINE('-- WARN: execute may run DML/SELECT in current session');
  END IF;
  IF v_sql_len >= 32000 THEN
    DBMS_OUTPUT.PUT_LINE(
      '-- WARN: SQL length near/over 32K; long execute uses DBMS_SQL');
  END IF;
  DBMS_OUTPUT.PUT_LINE('-- ============================================================');

  DBMS_OUTPUT.PUT_LINE('-- ----- original sql_fulltext (for SQLMAP / reference) -----');
  put_clob(v_sql_clob);
  DBMS_OUTPUT.PUT_LINE('-- ----- end original sql_fulltext -----');

  --------------------------------------------------------------------------
  -- No bind capture
  --------------------------------------------------------------------------
  IF v_bind_cnt = 0 THEN
    IF v_has_ph THEN
      DBMS_OUTPUT.PUT_LINE(
        '-- No rows in v$sql_bind_capture but SQL has placeholders ('
        || v_ph_type || ').');
      DBMS_OUTPUT.PUT_LINE(
        '-- Cannot safely execute. Re-run SQL to capture binds, or use print.');
      IF v_action = 'execute' THEN
        RAISE_APPLICATION_ERROR(c_err_no_bind,
          'placeholders present but no v$sql_bind_capture for sql_id='
          || v_sqlid || ' child=' || TO_CHAR(v_child));
      END IF;
      RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('-- No bind capture and no placeholders: direct sql_fulltext path');
    DBMS_OUTPUT.PUT_LINE('-- ----- generated anonymous block -----');
    IF v_action != 'execute' THEN
      DBMS_OUTPUT.PUT_LINE('SET SERVEROUTPUT ON');
    END IF;
    out_line('DECLARE');
    out_line('  v_prev VARCHAR2(128);');
    IF v_use_clob_gen OR v_sql_len >= c_ei_safe THEN
      out_line('  v_sql CLOB;');
      out_line('  v_run CLOB;');
      out_line('  v_cur INTEGER;');
      out_line('  v_ret INTEGER;');
    ELSE
      out_line('  v_sql VARCHAR2(32767);');
    END IF;
    out_line('BEGIN');
    out_line('  SELECT SYS_CONTEXT(''USERENV'',''CURRENT_SCHEMA'') INTO v_prev FROM DUAL;');
    IF v_schema_target IS NOT NULL THEN
      out_line('  EXECUTE IMMEDIATE ''ALTER SESSION SET CURRENT_SCHEMA = '
        || REPLACE(schema_ident(v_schema_target), '''', '''''') || ''';');
    END IF;
    IF v_use_clob_gen OR v_sql_len >= c_ei_safe THEN
      emit_sql_assign_clob(v_sql_clob);
      IF v_action = 'explain' THEN
        out_line('  DBMS_LOB.CREATETEMPORARY(v_run, TRUE);');
        out_line('  DBMS_LOB.WRITEAPPEND(v_run, 8, ''EXPLAIN '');');
        out_line('  DBMS_LOB.APPEND(v_run, v_sql);');
        out_line('  v_cur := DBMS_SQL.OPEN_CURSOR;');
        out_line('  DBMS_SQL.PARSE(v_cur, v_run, 1);');
        out_line('  v_ret := DBMS_SQL.EXECUTE(v_cur);');
        out_line('  DBMS_SQL.CLOSE_CURSOR(v_cur);');
      ELSE
        out_line('  v_cur := DBMS_SQL.OPEN_CURSOR;');
        out_line('  DBMS_SQL.PARSE(v_cur, v_sql, 1);');
        out_line('  v_ret := DBMS_SQL.EXECUTE(v_cur);');
        out_line('  DBMS_SQL.CLOSE_CURSOR(v_cur);');
      END IF;
    ELSE
      emit_sql_assign_varchar2(v_sql_clob);
      IF v_action = 'explain' THEN
        out_line('  EXECUTE IMMEDIATE ''EXPLAIN '' || v_sql;');
      ELSE
        out_line('  EXECUTE IMMEDIATE v_sql;');
      END IF;
    END IF;
    out_line('  IF v_prev IS NOT NULL THEN');
    out_line('    EXECUTE IMMEDIATE ''ALTER SESSION SET CURRENT_SCHEMA = '' || v_prev;');
    out_line('  END IF;');
    out_line('END;');
    DBMS_OUTPUT.PUT_LINE('/');
    DBMS_OUTPUT.PUT_LINE('-- ----- end generated block -----');

    IF v_action = 'execute' THEN
      do_execute(v_sql_clob, FALSE);
    END IF;
    RETURN;
  END IF;

  --------------------------------------------------------------------------
  -- With bind capture
  --------------------------------------------------------------------------
  DBMS_OUTPUT.PUT_LINE('-- ----- bind list -----');
  DBMS_OUTPUT.PUT_LINE(
    '-- POS | NAME | DATATYPE | WAS_CAPTURED | VALUE | WARN');
  v_pos_seen.DELETE;
  FOR r IN c_binds(v_sqlid, v_child) LOOP
    IF v_pos_seen.EXISTS(r.position) THEN
      NULL;
    ELSE
    v_pos_seen(r.position) := 1;
    v_warn := CASE
                WHEN NVL(UPPER(r.was_captured), 'NO') != 'YES' THEN 'WARN'
                WHEN r.value_string IS NULL
                     AND UPPER(NVL(r.datatype_string, 'X')) NOT IN ('NUMBER', 'DATE')
                     AND UPPER(NVL(r.datatype_string, 'X')) NOT LIKE 'TIMESTAMP%'
                     AND UPPER(NVL(r.datatype_string, 'X')) NOT LIKE 'NUMBER%'
                  THEN 'NULL'
                ELSE 'OK'
              END;
    DBMS_OUTPUT.PUT_LINE(
      '-- ' || TO_CHAR(r.position) || ' | ' || NVL(r.name, '(null)')
      || ' | ' || NVL(r.datatype_string, '-')
      || ' | ' || NVL(r.was_captured, '-')
      || ' | ' || NVL(SUBSTR(r.value_string, 1, 80), '(null)')
      || ' | ' || v_warn);
    END IF;
  END LOOP;

  DBMS_LOB.CREATETEMPORARY(v_replay_clob, TRUE);
  IF v_sql_len > 0 THEN
    DBMS_LOB.COPY(v_replay_clob, v_sql_clob, v_sql_len, 1, 1);
  END IF;

  v_decl := '';
  v_assign := '';
  v_using := '';
  v_bind_tab.DELETE;
  v_pos_seen.DELETE;
  v_idx := 0;

  FOR r IN c_binds(v_sqlid, v_child) LOOP
    IF v_pos_seen.EXISTS(r.position) THEN
      NULL;
    ELSE
    v_pos_seen(r.position) := 1;
    v_idx := v_idx + 1;
    v_var := 'v' || LPAD(TO_CHAR(v_idx), 3, '0');
    v_maxlen := NVL(r.max_length, 4000);
    IF v_maxlen < 1 THEN
      v_maxlen := 4000;
    END IF;
    v_dtype := plsql_type(r.datatype_string, v_maxlen);
    v_assign_expr := assign_expr(r.datatype_string, r.value_string);
    v_repl := ':B' || LPAD(TO_CHAR(v_idx), 3, '0');

    v_decl := v_decl || '  ' || v_var || ' ' || v_dtype || ';' || CHR(10);
    v_assign := v_assign || '  ' || v_var || ' := ' || v_assign_expr || ';' || CHR(10);
    IF v_using IS NULL OR LENGTH(v_using) = 0 THEN
      v_using := v_var;
    ELSE
      v_using := v_using || ', ' || v_var;
    END IF;

    -- execute binds: original names (business-sim). "?" path uses Bnnn on rewritten text.
    IF v_ph_type = 'question_mark' THEN
      v_bind_tab(v_idx).bname := 'B' || LPAD(TO_CHAR(v_idx), 3, '0');
    ELSE
      v_bind_tab(v_idx).bname := bind_var_name(r.name);
      IF v_bind_tab(v_idx).bname IS NULL THEN
        RAISE_APPLICATION_ERROR(c_err_rewrite,
          'empty bind name at position=' || TO_CHAR(r.position));
      END IF;
    END IF;
    v_bind_tab(v_idx).ds := r.datatype_string;
    v_bind_tab(v_idx).val_str := r.value_string;

    IF v_ph_type = 'question_mark' THEN
      v_qpos := find_question_clob(v_replay_clob);
      IF v_qpos = 0 THEN
        RAISE_APPLICATION_ERROR(c_err_rewrite,
          'no remaining ? while mapping position=' || TO_CHAR(r.position));
      END IF;
      clob_splice_replace(v_replay_clob, v_qpos, 1, v_repl);
    ELSE
      v_bind_pat := bind_pattern(r.name);
      IF v_bind_pat IS NULL THEN
        RAISE_APPLICATION_ERROR(c_err_rewrite,
          'empty bind name at position=' || TO_CHAR(r.position));
      END IF;
      v_qpos := find_pattern_clob(v_replay_clob, v_bind_pat);
      IF v_qpos = 0 THEN
        RAISE_APPLICATION_ERROR(c_err_rewrite,
          'bind pattern not found: ' || v_bind_pat
          || ' position=' || TO_CHAR(r.position));
      END IF;
      clob_splice_replace(v_replay_clob, v_qpos, LENGTH(v_bind_pat), v_repl);
    END IF;
    END IF; -- position dedupe
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('-- ----- generated anonymous block -----');
  IF v_action != 'execute' THEN
    DBMS_OUTPUT.PUT_LINE('SET SERVEROUTPUT ON');
  END IF;

  out_line('DECLARE');
  out_line('  v_prev VARCHAR2(128);');
  out_varchar_chunked(v_decl);
  IF v_use_clob_gen THEN
    out_line('  v_sql CLOB;');
    out_line('  v_run CLOB;');
  ELSE
    out_line('  v_sql VARCHAR2(32767);');
  END IF;
  out_line('BEGIN');
  out_line('  SELECT SYS_CONTEXT(''USERENV'',''CURRENT_SCHEMA'') INTO v_prev FROM DUAL;');
  IF v_schema_target IS NOT NULL THEN
    out_line('  EXECUTE IMMEDIATE ''ALTER SESSION SET CURRENT_SCHEMA = '
      || REPLACE(schema_ident(v_schema_target), '''', '''''') || ''';');
  END IF;
  out_varchar_chunked(v_assign);

  IF v_use_clob_gen THEN
    emit_sql_assign_clob(v_replay_clob);
    IF v_action = 'explain' THEN
      out_line('  -- explain only (no business DML execute)');
      out_line('  DBMS_LOB.CREATETEMPORARY(v_run, TRUE);');
      out_line('  DBMS_LOB.WRITEAPPEND(v_run, 8, ''EXPLAIN '');');
      out_line('  DBMS_LOB.APPEND(v_run, v_sql);');
      out_line('  EXECUTE IMMEDIATE v_run USING ' || v_using || ';');
    ELSE
      out_line('  -- run with captured bind values');
      out_line('  EXECUTE IMMEDIATE v_sql USING ' || v_using || ';');
    END IF;
  ELSE
    emit_sql_assign_varchar2(v_replay_clob);
    IF v_action = 'explain' THEN
      out_line('  -- explain only (no business DML execute)');
      out_line(
        '  EXECUTE IMMEDIATE ''EXPLAIN '' || v_sql USING ' || v_using || ';');
    ELSE
      out_line('  -- run with captured bind values');
      out_line('  EXECUTE IMMEDIATE v_sql USING ' || v_using || ';');
    END IF;
  END IF;
  out_line('  IF v_prev IS NOT NULL THEN');
  out_line('    EXECUTE IMMEDIATE ''ALTER SESSION SET CURRENT_SCHEMA = '' || v_prev;');
  out_line('  END IF;');
  out_line('END;');
  DBMS_OUTPUT.PUT_LINE('/');
  DBMS_OUTPUT.PUT_LINE('-- ----- end generated block -----');
  DBMS_OUTPUT.PUT_LINE(
    '-- NOTE: paste block rewrites binds to :Bnnn; execute uses ORIGINAL text+names');

  IF v_action = 'execute' THEN
    IF v_ph_type = 'question_mark' THEN
      DBMS_OUTPUT.PUT_LINE(
        '-- WARN: ? placeholders -> :Bnnn for DBMS_SQL; SQL text not byte-identical to JDBC');
      do_execute(v_replay_clob, FALSE);
    ELSE
      -- business-sim: unchanged sql_fulltext so hash/SQLMAP still match
      do_execute(v_sql_clob, FALSE);
    END IF;
  END IF;
END;
/
