-- File Name: sqlmap_gen_ddl.sql
-- Purpose: Generate CREATE SQLMAP DDL from an existing sqlmap name (read SYS.SQL_MAP$)
-- Created: 20260731  by  huangtingzhong
-- Updated: 20260814 by huangtingzhong (case-insensitive name; CLOB escape; UTF8-safe emit)
--
-- Usage: ytop/yasql -f sqlmap_gen_ddl.sql   (prompts for mapname)
--        ytop -E -f sqlmap_gen_ddl.sql --define mapname=<name>
-- Reads USER_NAME / SQL_TEXT / SQLMAP_TEXT from SYS.SQL_MAP$, escapes single quotes
-- via CLOB REPLACE (no VARCHAR2 4K chunk), prints DDL in small DBMS_OUTPUT chunks
-- (UTF8-safe). Join all CREATE... lines (drop newlines) before re-execution.

SET SERVEROUTPUT ON

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Generate CREATE SQLMAP DDL from existing sqlmap name                   |
PROMPT +------------------------------------------------------------------------+
PROMPT
PROMPT Enter mapname (sqlmap name):

DECLARE
  -- UTF8: SUBSTR into VARCHAR2(4000) may exceed byte limit; keep emit chunk small
  c_emit_chunk CONSTANT PLS_INTEGER := 1000;

  v_input  VARCHAR2(64) := TRIM('&&mapname');
  v_name   VARCHAR2(64);
  v_user   VARCHAR2(64);
  v_src    CLOB;
  v_tgt    CLOB;
  v_ddl    CLOB;
  v_cnt    NUMBER;
  v_q      VARCHAR2(1) := CHR(39);
  v_seg    VARCHAR2(4000);
  v_len    NUMBER;
  v_off    NUMBER;
  v_amt    NUMBER;

  -- Escape quotes on CLOB (avoid VARCHAR2 chunk / LENGTHB blow-up)
  PROCEDURE append_escaped(p_ddl IN OUT NOCOPY CLOB, p_clob IN CLOB) IS
    v_esc CLOB;
  BEGIN
    IF p_clob IS NULL THEN
      RETURN;
    END IF;
    v_esc := REPLACE(p_clob, v_q, v_q || v_q);
    IF v_esc IS NOT NULL AND DBMS_LOB.GETLENGTH(v_esc) > 0 THEN
      DBMS_LOB.APPEND(p_ddl, v_esc);
    END IF;
  END append_escaped;

  -- Emit CLOB via small PUT_LINE chunks (UTF8-safe)
  PROCEDURE put_clob(p_text IN CLOB) IS
    v_l PLS_INTEGER;
    v_o PLS_INTEGER := 1;
  BEGIN
    IF p_text IS NULL THEN
      RETURN;
    END IF;
    v_l := NVL(DBMS_LOB.GETLENGTH(p_text), 0);
    IF v_l = 0 THEN
      RETURN;
    END IF;
    WHILE v_o <= v_l LOOP
      v_amt := LEAST(c_emit_chunk, v_l - v_o + 1);
      DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(p_text, v_amt, v_o));
      v_o := v_o + v_amt;
    END LOOP;
  END put_clob;

BEGIN
  DBMS_OUTPUT.ENABLE(10000000);

  IF v_input IS NULL OR LENGTH(v_input) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('-- mapname is empty');
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM SYS.SQL_MAP$
   WHERE UPPER(name) = UPPER(v_input);
  IF v_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('-- sqlmap not found: ' || v_input);
    DBMS_OUTPUT.PUT_LINE('-- use sqlmap.sql to list existing sqlmaps');
    RETURN;
  END IF;
  IF v_cnt > 1 THEN
    DBMS_OUTPUT.PUT_LINE('-- WARN: ' || v_cnt ||
      ' rows match UPPER(name)=' || UPPER(v_input) || '; using first by name');
  END IF;

  SELECT name, user_name, sql_text, sqlmap_text
    INTO v_name, v_user, v_src, v_tgt
    FROM (
      SELECT name, NVL(user_name, 'ALL') AS user_name, sql_text, sqlmap_text
        FROM SYS.SQL_MAP$
       WHERE UPPER(name) = UPPER(v_input)
       ORDER BY name
    )
   WHERE ROWNUM = 1;

  -- Build DDL into CLOB (catalog name, not raw input case)
  DBMS_LOB.CREATETEMPORARY(v_ddl, TRUE);
  v_seg := 'CREATE SQLMAP ' || v_name || ' (' || v_user || ', ' || v_q;
  DBMS_LOB.WRITEAPPEND(v_ddl, LENGTH(v_seg), v_seg);
  append_escaped(v_ddl, v_src);
  v_seg := v_q || ', ' || v_q;
  DBMS_LOB.WRITEAPPEND(v_ddl, LENGTH(v_seg), v_seg);
  append_escaped(v_ddl, v_tgt);
  v_seg := v_q || ');';
  DBMS_LOB.WRITEAPPEND(v_ddl, LENGTH(v_seg), v_seg);

  v_len := DBMS_LOB.GETLENGTH(v_ddl);
  DBMS_OUTPUT.PUT_LINE('-- DDL for sqlmap: ' || v_name ||
                       '  (user=' || v_user || ', chars=' || v_len || ')');
  DBMS_OUTPUT.PUT_LINE('-- emit chunk=' || c_emit_chunk ||
                       '; join CREATE lines (strip newlines) before re-exec');
  put_clob(v_ddl);
END;
/
