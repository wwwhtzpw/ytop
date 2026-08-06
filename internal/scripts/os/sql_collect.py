#!/usr/bin/env python
# -*- coding: utf-8 -*-
# File Name: sql_collect.py
# Purpose: Collect gv$sql reports + HTZ backup; JDBC replay packages (keep ?/:binds)
# Created: 20260803 by huangtingzhong
# Updated: 20260804 by huangtingzhong (P0-P3 + bind types: DATE/TIMESTAMP, export gv bind, file latest child)
#
# Quick start:
#   python3 sql_collect.py replay --init-config
#   python3 sql_collect.py collect --interval 60 --log-dir ./logs
#   python3 sql_collect.py replay --source gv --sql-id a,b
#   python3 sql_collect.py replay --source gv --sql-id a --sessions 8
#   python3 sql_collect.py replay --source file --force
#   python3 sql_collect.py replay --source gv --sql-id a --dry-run
#   python3 sql_collect.py replay --schema-via-alter --source file --force
#   /usr/libexec/platform-python sql_collect.py --outdir ./sql_collect
#
# Subcommands:
#   collect (default if omitted): poll + HTZ backup + sql.sql + replay export
#   replay: JDBC only; --source file|htz|gv; executes by default; --dry-run to validate only;
#           query-only unless --force; --parallel N targets; --sessions N per SQL
#           --schema-via-alter: one [jdbc] login + ALTER SESSION CURRENT_SCHEMA (no map login)
#
# JDBC config (jar / url / user / password / [map.*] in one INI):
#   default load path: ./jdbc_replay.ini  (override: --jdbc-config /abs/or/rel/path)
#   optional [jdbc] schema_via_alter = true
#   generate template: python3 sql_collect.py replay --init-config [--overwrite]
#
# Logs (yinstall-style dual files under --log-dir, default ./logs):
#   sql_collect_<cmd>_<YYYYMMDDHHMMSS>.log       -- terminal mirror
#   sql_collect_<cmd>_debug_<YYYYMMDDHHMMSS>.log -- every background step
#   Terminal line: YYYY-MM-DD HH:MM:SS  message
#
# Rules (collect):
#   - default: single scan then exit
#   - --interval only: poll forever
#   - --count only: interval defaults to 600s (10 min)
#   - both set: use given interval and count
#
# Filters (noise) for reports:
#   - exclude parsing_schema SYS / SYSDBA
#   - exclude short / empty / ALTER SESSION / SET / tiny BEGIN blocks
#   - exclude collector self SQL (tag sql_collect_probe)
#
# Backup tables (mode B: insert only unseen object keys):
#   SYS.HTZ_GV_SQL              <- GV$SQL            key(inst_id,sql_id,child_number)
#   SYS.HTZ_GV_SQLSTATS         <- GV$SQLSTATS       key(inst_id,sql_id)
#   SYS.HTZ_GV_SQL_BIND_CAPTURE <- GV$SQL_BIND_CAPTURE
#   SYS.HTZ_GV_SQL_PLAN         <- GV$SQL_PLAN       key(inst_id,sql_id,child_number,plan_hash_value,id)
#                                 key(inst_id,sql_id,child_number,position,name)
#   Note: Yashan has GV$SQLSTATS (not GV$SQL_STAT).
#
# Replay package (also SYS.HTZ_SQL_REPLAY_PKG):
#   outdir/replay/<sql_id>__c<child>/{orig.sql,binds.json,binds.txt,meta.txt}
#
# JDBC INI (default ./jdbc_replay.ini):
#   [jdbc]
#   jdbc_jar = /path/to/yashandb-jdbc-*.jar
#   jdbc_url = jdbc:yasdb://10.10.10.170:1688/yasdb
#   user = htz              # catalog lookup (gv$/HTZ_*) + empty-schema fallback
#   password = ******       # fallback password if no [map.SCHEMA]
#   [map.HTZ]               # optional per parsing_schema login
#   user = htz              # omit => section schema name
#   password = ******
#   Missing map: WARN + try schema name + [jdbc] password
#   jdbc_url is required (no host/port fallback)
#
# Output:
#   outdir/<sql_id>.txt          -- full sql.sql report
#   outdir/collected_sqlids.txt  -- one sql_id per line (already collected)
#     Exception: if replay package has bind slots with empty values (or package
#     missing), next collect round may BIND-REFRESH re-export — but only when
#     v$/gv$sql_bind_capture has more non-empty values than the package
#     (avoids identical empty-bind spam every interval).

from __future__ import print_function, unicode_literals

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import configparser
except ImportError:
    import ConfigParser as configparser  # type: ignore

try:
    from subprocess import DEVNULL
except ImportError:
    DEVNULL = open(os.devnull, "w")

PROG = "sql_collect.py"
VERSION = "1.7.18"
APP_AUTHOR = "huangtingzhong"
APP_CONTACT = ""
DEFAULT_CONNECT = "/ as sysdba"
DEFAULT_YASQL = "yasql"
DEFAULT_LOG_DIR = "logs"
DEFAULT_JDBC_CONFIG = "./jdbc_replay.ini"
LOG_TS_FMT = "%Y%m%d%H%M%S"
LOG_LINE_TS = "%Y-%m-%d %H:%M:%S"
LOG_LEVEL_WIDTH = 5  # INFO/WARN/ERROR/DEBUG/STEP aligned column
DEFAULT_OUTDIR = "./sql_collect"
DEFAULT_INTERVAL_WITH_COUNT = 600
COLLECTED_FILE = "collected_sqlids.txt"
REPLAY_DIRNAME = "replay"
PROBE_TAG = "sql_collect_probe"
EXCLUDE_SCHEMAS = ("SYS", "SYSDBA")
MIN_SQL_CHARS = 20
YASQL_TIMEOUT = 600
JDBC_TIMEOUT = 600
CLOB_CHUNK = 1000

# Marker lines for parsing list query output
MARK_START = "SQL_COLLECT_ID_START"
MARK_END = "SQL_COLLECT_ID_END"


MARK_BACKUP_START = "SQL_COLLECT_BACKUP_START"
MARK_BACKUP_END = "SQL_COLLECT_BACKUP_END"

MARK_REPLAY_META_START = "SQL_COLLECT_REPLAY_META_START"
MARK_REPLAY_META_END = "SQL_COLLECT_REPLAY_META_END"
MARK_REPLAY_BIND_START = "SQL_COLLECT_REPLAY_BIND_START"
MARK_REPLAY_BIND_END = "SQL_COLLECT_REPLAY_BIND_END"
MARK_REPLAY_ORIG_START = "SQL_COLLECT_REPLAY_ORIG_START"
MARK_REPLAY_ORIG_END = "SQL_COLLECT_REPLAY_ORIG_END"

# Incremental object backup into SYS.HTZ_GV_* (create if missing; insert unseen keys only)
BACKUP_SQL = (
    "SET SERVEROUTPUT ON\n"
    "DECLARE\n"
    "  v_cnt NUMBER;\n"
    "  v_ins NUMBER;\n"
    "  v_t0 DATE := SYSDATE;\n"
    "  v_n_sid NUMBER := 0;\n"
    "\n"
    "  PROCEDURE ensure_table(p_table IN VARCHAR2, p_ctas IN VARCHAR2) IS\n"
    "    v_n NUMBER;\n"
    "  BEGIN\n"
    "    SELECT COUNT(*) INTO v_n\n"
    "      FROM dba_tables\n"
    "     WHERE owner = 'SYS' AND table_name = UPPER(p_table);\n"
    "    IF v_n = 0 THEN\n"
    "      EXECUTE IMMEDIATE p_ctas;\n"
    "      DBMS_OUTPUT.PUT_LINE('TABLE ' || p_table || ' created');\n"
    "    ELSE\n"
    "      DBMS_OUTPUT.PUT_LINE('TABLE ' || p_table || ' exists');\n"
    "    END IF;\n"
    "  END;\n"
    "BEGIN\n"
    "  DBMS_OUTPUT.PUT_LINE('" + MARK_BACKUP_START + "');\n"
    "\n"
    "  ensure_table(\n"
    "    'HTZ_GV_SQL',\n"
    "    'CREATE TABLE SYS.HTZ_GV_SQL AS SELECT g.*, CAST(NULL AS DATE) AS COLLECT_TIME FROM GV$SQL g WHERE 1=0'\n"
    "  );\n"
    "  ensure_table(\n"
    "    'HTZ_GV_SQLSTATS',\n"
    "    'CREATE TABLE SYS.HTZ_GV_SQLSTATS AS SELECT g.*, CAST(NULL AS DATE) AS COLLECT_TIME FROM GV$SQLSTATS g WHERE 1=0'\n"
    "  );\n"
    "  ensure_table(\n"
    "    'HTZ_GV_SQL_BIND_CAPTURE',\n"
    "    'CREATE TABLE SYS.HTZ_GV_SQL_BIND_CAPTURE AS SELECT g.*, CAST(NULL AS DATE) AS COLLECT_TIME FROM GV$SQL_BIND_CAPTURE g WHERE 1=0'\n"
    "  );\n"
    "  ensure_table(\n"
    "    'HTZ_GV_SQL_PLAN',\n"
    "    'CREATE TABLE SYS.HTZ_GV_SQL_PLAN AS SELECT g.*, CAST(NULL AS DATE) AS COLLECT_TIME FROM GV$SQL_PLAN g WHERE 1=0'\n"
    "  );\n"
    "\n"
    "  -- dynamic DML: avoid compile-time check on HTZ_* before create\n"
    "  EXECUTE IMMEDIATE\n"
    "    'INSERT INTO SYS.HTZ_GV_SQL\n"
    "     SELECT g.*, SYSDATE FROM GV$SQL g\n"
    "      WHERE g.sql_id IS NOT NULL\n"
    "        AND UPPER(NVL(g.parsing_schema_name, ''X'')) NOT IN (''SYS'', ''SYSDBA'')\n"
    "        AND (g.sql_fulltext IS NULL OR DBMS_LOB.INSTR(g.sql_fulltext, ''sql_collect_probe'') = 0)\n"
    "        AND NOT EXISTS (\n"
    "              SELECT 1 FROM SYS.HTZ_GV_SQL h\n"
    "               WHERE h.inst_id = g.inst_id\n"
    "                 AND h.sql_id = g.sql_id\n"
    "                 AND h.child_number = g.child_number)';\n"
    "  v_ins := SQL%ROWCOUNT;\n"
    "  DBMS_OUTPUT.PUT_LINE('INSERT HTZ_GV_SQL rows=' || TO_CHAR(v_ins));\n"
    "\n"
    "  EXECUTE IMMEDIATE\n"
    "    'INSERT INTO SYS.HTZ_GV_SQLSTATS\n"
    "     SELECT s.*, SYSDATE FROM GV$SQLSTATS s\n"
    "      WHERE s.sql_id IS NOT NULL\n"
    "        AND EXISTS (\n"
    "              SELECT 1 FROM GV$SQL g\n"
    "               WHERE g.inst_id = s.inst_id\n"
    "                 AND g.sql_id = s.sql_id\n"
    "                 AND UPPER(NVL(g.parsing_schema_name, ''X'')) NOT IN (''SYS'', ''SYSDBA''))\n"
    "        AND NOT EXISTS (\n"
    "              SELECT 1 FROM SYS.HTZ_GV_SQLSTATS h\n"
    "               WHERE h.inst_id = s.inst_id\n"
    "                 AND h.sql_id = s.sql_id)';\n"
    "  v_ins := SQL%ROWCOUNT;\n"
    "  DBMS_OUTPUT.PUT_LINE('INSERT HTZ_GV_SQLSTATS rows=' || TO_CHAR(v_ins));\n"
    "\n"
    "  EXECUTE IMMEDIATE\n"
    "    'INSERT INTO SYS.HTZ_GV_SQL_BIND_CAPTURE\n"
    "     SELECT b.*, SYSDATE FROM GV$SQL_BIND_CAPTURE b\n"
    "      WHERE b.sql_id IS NOT NULL\n"
    "        AND EXISTS (\n"
    "              SELECT 1 FROM GV$SQL g\n"
    "               WHERE g.inst_id = b.inst_id\n"
    "                 AND g.sql_id = b.sql_id\n"
    "                 AND g.child_number = b.child_number\n"
    "                 AND UPPER(NVL(g.parsing_schema_name, ''X'')) NOT IN (''SYS'', ''SYSDBA''))\n"
    "        AND NOT EXISTS (\n"
    "              SELECT 1 FROM SYS.HTZ_GV_SQL_BIND_CAPTURE h\n"
    "               WHERE h.inst_id = b.inst_id\n"
    "                 AND h.sql_id = b.sql_id\n"
    "                 AND h.child_number = b.child_number\n"
    "                 AND h.position = b.position\n"
    "                 AND NVL(h.name, CHR(0)) = NVL(b.name, CHR(0)))';\n"
    "  v_ins := SQL%ROWCOUNT;\n"
    "  DBMS_OUTPUT.PUT_LINE('INSERT HTZ_GV_SQL_BIND_CAPTURE rows=' || TO_CHAR(v_ins));\n"
    "\n"
    "  EXECUTE IMMEDIATE\n"
    "    'INSERT INTO SYS.HTZ_GV_SQL_PLAN\n"
    "     SELECT p.*, SYSDATE FROM GV$SQL_PLAN p\n"
    "      WHERE p.sql_id IS NOT NULL\n"
    "        AND p.id IS NOT NULL\n"
    "        AND EXISTS (\n"
    "              SELECT 1 FROM GV$SQL g\n"
    "               WHERE g.inst_id = p.inst_id\n"
    "                 AND g.sql_id = p.sql_id\n"
    "                 AND NVL(g.child_number, -1) = NVL(p.child_number, -1)\n"
    "                 AND UPPER(NVL(g.parsing_schema_name, ''X'')) NOT IN (''SYS'', ''SYSDBA'')\n"
    "                 AND (g.sql_fulltext IS NULL OR DBMS_LOB.INSTR(g.sql_fulltext, ''sql_collect_probe'') = 0))\n"
    "        AND NOT EXISTS (\n"
    "              SELECT 1 FROM SYS.HTZ_GV_SQL_PLAN h\n"
    "               WHERE h.inst_id = p.inst_id\n"
    "                 AND h.sql_id = p.sql_id\n"
    "                 AND NVL(h.child_number, -1) = NVL(p.child_number, -1)\n"
    "                 AND NVL(h.plan_hash_value, -1) = NVL(p.plan_hash_value, -1)\n"
    "                 AND NVL(h.id, -1) = NVL(p.id, -1))';\n"
    "  v_ins := SQL%ROWCOUNT;\n"
    "  DBMS_OUTPUT.PUT_LINE('INSERT HTZ_GV_SQL_PLAN rows=' || TO_CHAR(v_ins));\n"
    "\n"
    "  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM SYS.HTZ_GV_SQL' INTO v_cnt;\n"
    "  DBMS_OUTPUT.PUT_LINE('TOTAL HTZ_GV_SQL rows=' || TO_CHAR(v_cnt));\n"
    "  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM SYS.HTZ_GV_SQLSTATS' INTO v_cnt;\n"
    "  DBMS_OUTPUT.PUT_LINE('TOTAL HTZ_GV_SQLSTATS rows=' || TO_CHAR(v_cnt));\n"
    "  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM SYS.HTZ_GV_SQL_BIND_CAPTURE' INTO v_cnt;\n"
    "  DBMS_OUTPUT.PUT_LINE('TOTAL HTZ_GV_SQL_BIND_CAPTURE rows=' || TO_CHAR(v_cnt));\n"
    "  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM SYS.HTZ_GV_SQL_PLAN' INTO v_cnt;\n"
    "  DBMS_OUTPUT.PUT_LINE('TOTAL HTZ_GV_SQL_PLAN rows=' || TO_CHAR(v_cnt));\n"
    "\n"
    "  DECLARE\n"
    "    TYPE t_ids IS TABLE OF VARCHAR2(64);\n"
    "    l_ids t_ids;\n"
    "  BEGIN\n"
    "    EXECUTE IMMEDIATE\n"
    "      'SELECT sql_id FROM (\n"
    "          SELECT DISTINCT sql_id FROM SYS.HTZ_GV_SQL WHERE collect_time >= :1\n"
    "          UNION\n"
    "          SELECT DISTINCT sql_id FROM SYS.HTZ_GV_SQLSTATS WHERE collect_time >= :2\n"
    "          UNION\n"
    "          SELECT DISTINCT sql_id FROM SYS.HTZ_GV_SQL_BIND_CAPTURE WHERE collect_time >= :3\n"
    "          UNION\n"
    "          SELECT DISTINCT sql_id FROM SYS.HTZ_GV_SQL_PLAN WHERE collect_time >= :4\n"
    "       ) ORDER BY 1'\n"
    "      BULK COLLECT INTO l_ids\n"
    "      USING v_t0, v_t0, v_t0, v_t0;\n"
    "    IF l_ids IS NOT NULL THEN\n"
    "      FOR i IN 1 .. l_ids.COUNT LOOP\n"
    "        v_n_sid := v_n_sid + 1;\n"
    "        DBMS_OUTPUT.PUT_LINE('BACKUP_SQLID=' || l_ids(i));\n"
    "      END LOOP;\n"
    "    END IF;\n"
    "  END;\n"
    "  DBMS_OUTPUT.PUT_LINE('BACKUP_NEW_N=' || TO_CHAR(v_n_sid));\n"
    "\n"
    "  COMMIT;\n"
    "  DBMS_OUTPUT.PUT_LINE('" + MARK_BACKUP_END + "');\n"
    "END;\n"
    "/\n"
    "EXIT;\n"
)

def run_backup_incremental(connect_str, yasql_path):
    # type: (str, str) -> tuple
    """
    Create SYS.HTZ_GV_* if needed; insert unseen object keys.
    Return (ok, new_sql_ids) — new_sql_ids are distinct sql_id inserted this round.
    """
    path = write_temp_sql(BACKUP_SQL)
    try:
        rc, out = yasql_run(path, connect_str, yasql_path, timeout=600)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    ok = rc == 0 and MARK_BACKUP_START in out and MARK_BACKUP_END in out
    new_ids = []
    if not ok:
        eprint("[ERROR] backup incremental failed rc={0}".format(rc))
        eprint(out[-3000:] if out else "(no output)")
        return False, new_ids
    for ln in out.splitlines():
        s = ln.strip()
        if s.startswith("BACKUP_SQLID="):
            sid = s.split("=", 1)[1].strip()
            if sid:
                new_ids.append(sid)
        elif s.startswith("TABLE ") and s.endswith(" created"):
            log_info("backup {0}".format(s))
        elif (
            s.startswith("TABLE ")
            or s.startswith("INSERT ")
            or s.startswith("TOTAL ")
            or s.startswith("BACKUP_NEW_N=")
        ):
            log_dbg("backup {0}".format(s))
    # dedupe preserve order
    seen = set()
    ordered = []
    for sid in new_ids:
        if sid not in seen:
            seen.add(sid)
            ordered.append(sid)
    return True, ordered



# Embedded tuning report (from sql/yashandb/sql.sql). Uses &&sqlid.
EMBEDDED_SQL_REPORT = r"""
-- File Name: sql.sql
-- Purpose: YashanDB SQL tuning report (ORIGINAL+LITERAL SQL, plan, objects)
-- Created: 20251201  by  huangtingzhong
-- Updated: 20260805 by huangtingzhong (LITERAL: prefer :SYS_B even with ?; enlarge/truncate repl)

set heading on;
set serveroutput on;
prompt
prompt ****************************************************************************************
prompt ORIGINAL SQL / LITERAL SQL
prompt ****************************************************************************************

DECLARE
  c_sqlid           CONSTANT VARCHAR2(64) := '&&sqlid';
  -- UTF8: SUBSTR into VARCHAR2(4000) may exceed byte limit; keep emit chunk small
  c_chunk           CONSTANT PLS_INTEGER := 1000;
  c_varchar_limit   CONSTANT PLS_INTEGER := 32000;

  lvc_sql_text      VARCHAR2(32000);
  lvc_orig_sql_text CLOB;
  ln_child          NUMBER := 10000;
  ln_exec_child     NUMBER;
  ln_hash           NUMBER;
  ln_phv            NUMBER;
  ln_sql_len        NUMBER;
  lvc_repl          VARCHAR2(8000);
  lvc_bind          VARCHAR2(200);
  lvc_name          VARCHAR2(64);
  lvc_sql_tmp       VARCHAR2(32767);

  ln_bind_count     NUMBER := 0;
  ln_sql_cnt        NUMBER := 0;
  ln_qpos           NUMBER;

  TYPE t_pos_seen IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
  v_pos_seen        t_pos_seen;

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
    IF v_len = 0 THEN
      RETURN;
    END IF;
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

  FUNCTION replace_first_outside_quotes(
    p_text        IN VARCHAR2,
    p_pattern     IN VARCHAR2,
    p_replacement IN VARCHAR2
  ) RETURN VARCHAR2 IS
    v_pos      PLS_INTEGER := 1;
    v_len      PLS_INTEGER := NVL(LENGTH(p_text), 0);
    v_plen     PLS_INTEGER := NVL(LENGTH(p_pattern), 0);
    v_in_quote BOOLEAN := FALSE;
    v_result   VARCHAR2(32767) := '';
    v_ch       CHAR(1);
    v_next     CHAR(1);
  BEGIN
    IF v_len = 0 OR v_plen = 0 THEN
      RETURN p_text;
    END IF;

    WHILE v_pos <= v_len LOOP
      v_ch := SUBSTR(p_text, v_pos, 1);

      IF v_ch = '''' THEN
        IF v_in_quote
           AND v_pos < v_len
           AND SUBSTR(p_text, v_pos + 1, 1) = '''' THEN
          v_result := v_result || '''''';
          v_pos := v_pos + 2;
        ELSE
          v_in_quote := NOT v_in_quote;
          v_result := v_result || v_ch;
          v_pos := v_pos + 1;
        END IF;
      ELSIF NOT v_in_quote
            AND v_pos + v_plen - 1 <= v_len
            AND UPPER(SUBSTR(p_text, v_pos, v_plen)) = UPPER(p_pattern) THEN
        v_next := CASE
                    WHEN v_pos + v_plen <= v_len THEN SUBSTR(p_text, v_pos + v_plen, 1)
                    ELSE NULL
                  END;
        IF p_pattern LIKE ':%'
           AND v_next IS NOT NULL
           AND v_next BETWEEN '0' AND '9' THEN
          v_result := v_result || v_ch;
          v_pos := v_pos + 1;
        ELSE
          RETURN v_result || p_replacement || SUBSTR(p_text, v_pos + v_plen);
        END IF;
      ELSE
        v_result := v_result || v_ch;
        v_pos := v_pos + 1;
      END IF;
    END LOOP;

    RETURN v_result;
  END replace_first_outside_quotes;

  FUNCTION bind_pattern(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    v_bare VARCHAR2(128);
  BEGIN
    IF p_name IS NULL OR LENGTH(TRIM(p_name)) = 0 OR TRIM(p_name) = '?' THEN
      RETURN NULL;
    END IF;
    -- SYS_B: SQL text usually :SYS_B_0 (unquoted); some tools use :"SYS_B_0"
    IF UPPER(LTRIM(p_name, ':')) LIKE 'SYS_B_%'
       OR UPPER(REPLACE(LTRIM(p_name, ':'), '"', '')) LIKE 'SYS_B_%' THEN
      v_bare := REPLACE(LTRIM(p_name, ':'), '"', '');
      RETURN ':' || v_bare;
    ELSIF p_name LIKE ':%' THEN
      RETURN p_name;
    ELSE
      RETURN ':' || LTRIM(p_name, ':');
    END IF;
  END bind_pattern;

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
  END bind_pattern_alt;

  FUNCTION uses_question_bind(p_text IN VARCHAR2) RETURN BOOLEAN IS
    v_pos      PLS_INTEGER := 1;
    v_len      PLS_INTEGER := NVL(LENGTH(p_text), 0);
    v_in_quote BOOLEAN := FALSE;
    v_ch       CHAR(1);
  BEGIN
    WHILE v_pos <= v_len LOOP
      v_ch := SUBSTR(p_text, v_pos, 1);
      IF v_ch = '''' THEN
        IF v_in_quote
           AND v_pos < v_len
           AND SUBSTR(p_text, v_pos + 1, 1) = '''' THEN
          v_pos := v_pos + 2;
        ELSE
          v_in_quote := NOT v_in_quote;
          v_pos := v_pos + 1;
        END IF;
      ELSIF NOT v_in_quote AND v_ch = '?' THEN
        RETURN TRUE;
      ELSE
        v_pos := v_pos + 1;
      END IF;
    END LOOP;
    RETURN FALSE;
  END uses_question_bind;

BEGIN
  SELECT COUNT(*)
    INTO ln_sql_cnt
    FROM v$sql
   WHERE sql_id = c_sqlid;

  IF ln_sql_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No SQL found in V$SQL for sql_id=' || c_sqlid);
    RETURN;
  END IF;

  -- ORIGINAL: prefer child with non-empty bind capture, else last_active_time
  SELECT sql_fulltext,
         parsing_schema_name,
         child_number,
         hash_value,
         plan_hash_value,
         NVL(DBMS_LOB.GETLENGTH(sql_fulltext), 0)
    INTO lvc_orig_sql_text,
         lvc_name,
         ln_exec_child,
         ln_hash,
         ln_phv,
         ln_sql_len
    FROM (
           SELECT s.sql_fulltext,
                  s.parsing_schema_name,
                  s.child_number,
                  s.hash_value,
                  s.plan_hash_value,
                  s.last_active_time,
                  s.executions
             FROM v$sql s
            WHERE s.sql_id = c_sqlid
            ORDER BY s.last_active_time DESC NULLS LAST,
                   s.executions DESC NULLS LAST,
                   s.child_number
         )
   WHERE ROWNUM = 1;

  DBMS_OUTPUT.PUT_LINE('===== ORIGINAL SQL =====');
  DBMS_OUTPUT.PUT_LINE(
    'source=v$sql.sql_fulltext (executed cursor) sql_id=' || c_sqlid
    || ' child=' || TO_CHAR(ln_exec_child)
    || ' schema=' || lvc_name
    || ' hash=' || TO_CHAR(ln_hash)
    || ' phv=' || TO_CHAR(ln_phv)
    || ' chars=' || TO_CHAR(ln_sql_len)
  );
  put_clob(lvc_orig_sql_text);
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');

  SELECT COUNT(*)
    INTO ln_bind_count
    FROM v$sql_bind_capture
   WHERE sql_id = c_sqlid
     AND child_number = ln_exec_child
     AND last_captured IS NOT NULL
     AND ROWNUM = 1;

  IF ln_bind_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE('===== LITERAL SQL =====');
    DBMS_OUTPUT.PUT_LINE(
      'Schema: ' || lvc_name || ' child=' || TO_CHAR(ln_exec_child)
      || ' (no bind capture on executed child; same as ORIGINAL SQL)'
    );
    put_clob(lvc_orig_sql_text);
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
    RETURN;
  END IF;

  IF ln_sql_len > c_varchar_limit THEN
    DBMS_OUTPUT.PUT_LINE('===== LITERAL SQL =====');
    DBMS_OUTPUT.PUT_LINE(
      'WARN: SQL chars=' || TO_CHAR(ln_sql_len)
      || ' > ' || TO_CHAR(c_varchar_limit)
      || '; bind literal rewrite skipped (see ORIGINAL SQL)'
    );
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
    RETURN;
  END IF;

  -- short SQL: bind rewrite on VARCHAR2 copy of executed text
  lvc_sql_text := DBMS_LOB.SUBSTR(lvc_orig_sql_text, ln_sql_len, 1);

  v_pos_seen.DELETE;
  FOR r1 IN c1(ln_exec_child) LOOP
    IF NOT v_pos_seen.EXISTS(r1.position) THEN
    v_pos_seen(r1.position) := 1;
    IF (r1.child_number <> ln_child) THEN
      IF ln_child <> 10000 THEN
        DBMS_OUTPUT.PUT_LINE('===== LITERAL SQL =====');
        DBMS_OUTPUT.PUT_LINE('Schema: ' || lvc_name || ' child=' || TO_CHAR(ln_child));
        put_varchar(lvc_sql_text);
        DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
      END IF;

      ln_child     := r1.child_number;
      lvc_sql_text := DBMS_LOB.SUBSTR(lvc_orig_sql_text, ln_sql_len, 1);
    END IF;

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

    IF r1.value_string IS NULL THEN
      lvc_repl := 'NULL';
    ELSIF r1.datatype_string = 'NUMBER' THEN
      IF LENGTH(r1.value_string) > 7900 THEN
        lvc_repl := SUBSTR(r1.value_string, 1, 7900);
      ELSE
        lvc_repl := r1.value_string;
      END IF;
    ELSIF r1.datatype_string = 'DATE' THEN
      lvc_repl := 'to_date(''' || REPLACE(SUBSTR(NVL(r1.value_string, ''), 1, 7800), '''', '''''') || ''')';
    ELSIF r1.datatype_string LIKE 'TIMESTAMP%' THEN
      lvc_repl := 'to_timestamp(''' || REPLACE(SUBSTR(NVL(r1.value_string, ''), 1, 7800), '''', '''''') || ''')';
    ELSE
      -- avoid YAS-04412 when value_string exceeds old VARCHAR2(2000) repl buffer
      lvc_repl := '''' || REPLACE(SUBSTR(NVL(r1.value_string, ''), 1, 7800), '''', '''''') || '''';
      IF LENGTH(NVL(r1.value_string, '')) > 7800 THEN
        lvc_repl := lvc_repl || ' /*truncated*/';
      END IF;
    END IF;

    lvc_bind := bind_pattern(r1.name);

    -- Prefer named placeholders even when SQL also has trailing ? (pagination)
    IF lvc_bind IS NOT NULL THEN
      lvc_sql_tmp := replace_first_outside_quotes(lvc_sql_text, lvc_bind, lvc_repl);
      IF lvc_sql_tmp = lvc_sql_text AND bind_pattern_alt(r1.name) IS NOT NULL THEN
        lvc_sql_tmp := replace_first_outside_quotes(
          lvc_sql_text, bind_pattern_alt(r1.name), lvc_repl);
      END IF;
      IF lvc_sql_tmp <> lvc_sql_text THEN
        lvc_sql_text := lvc_sql_tmp;
      ELSE
        ln_qpos := INSTR(lvc_sql_text, '?');
        IF ln_qpos = 0 THEN
          DBMS_OUTPUT.PUT_LINE(
            'ERROR: no placeholder for bind position=' || r1.position
            || ', name=' || NVL(r1.name, '(null)')
          );
          RETURN;
        END IF;
        lvc_sql_text :=
          SUBSTR(lvc_sql_text, 1, ln_qpos - 1) ||
          lvc_repl ||
          SUBSTR(lvc_sql_text, ln_qpos + 1);
      END IF;
    ELSE
      ln_qpos := INSTR(lvc_sql_text, '?');
      IF ln_qpos = 0 THEN
        DBMS_OUTPUT.PUT_LINE(
          'ERROR: no remaining ''?'' placeholders while replacing binds. ' ||
          'bind position=' || r1.position || ', name=' || NVL(r1.name, '(null)')
        );
        RETURN;
      END IF;

      lvc_sql_text :=
        SUBSTR(lvc_sql_text, 1, ln_qpos - 1) ||
        lvc_repl ||
        SUBSTR(lvc_sql_text, ln_qpos + 1);
    END IF;
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('===== LITERAL SQL =====');
  DBMS_OUTPUT.PUT_LINE(
    'Schema: ' || lvc_name || ' child=' || TO_CHAR(ln_exec_child)
    || ' (bind values from capture; not byte-identical to execute)'
  );
  put_varchar(lvc_sql_text);
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
END;
/



prompt ****************************************************************************************
prompt PLAN from v$sql_plan
prompt ****************************************************************************************

-- Pure SQL plan (no DBMS_OUTPUT); works on READ_ONLY standby.
-- Do not set "col plan_line for aN": yasql pads every row to N chars.

-- One row per (plan_hash_value, id): collapse multi-child / multi-address
-- copies in v$sql_plan so each PHV prints a single plan tree.
WITH ranked AS (
  SELECT p.plan_hash_value AS phv,
         p.id,
         p.parent_id,
         p.depth,
         p.operation,
         p.options,
         p.object_owner,
         p.object_name,
         p.object_type,
         p.object_alias,
         p.cost,
         p.cardinality,
         p.bytes,
         p.time AS plan_time,
         p.cpu_cost,
         p.io_cost,
         p.search_columns,
         p.access_predicates,
         p.filter_predicates,
         p.projection,
         p.partition_info,
         p.partition_start,
         p.partition_stop,
         p.other_tag,
         p.temp_space,
         LPAD(' ', NVL(p.depth, 0) * 2) || p.operation || NVL(' ' || p.options, '') AS op_txt,
         CASE
           WHEN p.object_name IS NOT NULL THEN
             p.object_owner || '.' || p.object_name ||
             CASE
               WHEN p.object_type IS NOT NULL THEN ' [' || p.object_type || ']'
               ELSE ''
             END ||
             CASE
               WHEN LENGTH(TRIM(NVL(p.object_alias, ''))) > 0
               THEN ' (' || TRIM(p.object_alias) || ')'
               ELSE ''
             END
           WHEN LENGTH(TRIM(NVL(p.object_alias, ''))) > 0 THEN
             TRIM(p.object_alias)
           ELSE NULL
         END AS name_txt,
         CASE
           WHEN LENGTH(TRIM(NVL(p.access_predicates, ''))) > 0
           THEN '  -> Access: ' || p.access_predicates
         END AS access_txt,
         CASE
           WHEN LENGTH(TRIM(NVL(p.filter_predicates, ''))) > 0
           THEN '  -> Filter: ' || p.filter_predicates
         END AS filter_txt,
         -- Prefer PARTITION_INFO; append PARTITION_START..STOP when non-zero
         CASE
           WHEN LENGTH(TRIM(NVL(p.partition_info, ''))) > 0 THEN
             '  -> Partition: ' || TRIM(p.partition_info) ||
             CASE
               WHEN NVL(p.partition_start, 0) <> 0 OR NVL(p.partition_stop, 0) <> 0
               THEN ' (' || NVL(TO_CHAR(p.partition_start), '?') || '..' ||
                    NVL(TO_CHAR(p.partition_stop), '?') || ')'
               ELSE ''
             END
           WHEN NVL(p.partition_start, 0) <> 0 OR NVL(p.partition_stop, 0) <> 0 THEN
             '  -> Partition: ' ||
             NVL(TO_CHAR(p.partition_start), '?') || '..' ||
             NVL(TO_CHAR(p.partition_stop), '?')
         END AS part_txt,
         CASE
           WHEN LENGTH(TRIM(NVL(p.other_tag, ''))) > 0
           THEN '  -> Other: ' || TRIM(p.other_tag)
         END AS other_txt,
         CASE
           WHEN NVL(p.temp_space, 0) <> 0
           THEN '  -> Temp: ' || TO_CHAR(p.temp_space)
         END AS temp_txt,
         CASE
           WHEN NVL(p.search_columns, 0) <> 0
           THEN '  -> SearchCols: ' || TO_CHAR(p.search_columns)
         END AS search_txt,
         CASE
           WHEN NVL(p.cpu_cost, 0) <> 0 OR NVL(p.io_cost, 0) <> 0
           THEN '  -> CpuIo: cpu=' || NVL(TO_CHAR(p.cpu_cost), '0') ||
                ' io=' || NVL(TO_CHAR(p.io_cost), '0')
         END AS cpuio_txt,
         CASE
           WHEN LENGTH(TRIM(NVL(p.projection, ''))) > 0
           THEN '  -> Projection: ' || p.projection
         END AS proj_txt,
         ROW_NUMBER() OVER (
           PARTITION BY p.plan_hash_value, p.id
           ORDER BY p.child_number NULLS LAST, p.child_address, p.address
         ) AS rn
    FROM v$sql_plan p
   WHERE p.sql_id = '&&sqlid'
     AND p.id IS NOT NULL
     AND p.operation IS NOT NULL
),
base AS (
  SELECT phv, id, parent_id, depth, operation, options,
         object_owner, object_name, object_type, object_alias,
         cost, cardinality, bytes, plan_time, cpu_cost, io_cost,
         search_columns, access_predicates, filter_predicates, projection,
         partition_info, partition_start, partition_stop, other_tag, temp_space,
         op_txt, name_txt, access_txt, filter_txt, part_txt, other_txt,
         temp_txt, search_txt, cpuio_txt, proj_txt
    FROM ranked
   WHERE rn = 1
),
w AS (
  SELECT phv,
         GREATEST(LENGTH('Id'), NVL(MAX(LENGTH(TO_CHAR(id))), 0)) AS w_id,
         GREATEST(LENGTH('Pid'), NVL(MAX(LENGTH(TO_CHAR(parent_id))), 0)) AS w_pid,
         GREATEST(LENGTH('Ord'), NVL(MAX(LENGTH(TO_CHAR(id))), 0)) AS w_ord,
         LEAST(
           120,
           GREATEST(
             LENGTH('Operation'),
             NVL(MAX(LENGTH(op_txt)), 0),
             NVL(MAX(LENGTH(access_txt)), 0),
             NVL(MAX(LENGTH(filter_txt)), 0),
             NVL(MAX(LENGTH(part_txt)), 0),
             NVL(MAX(LENGTH(other_txt)), 0),
             NVL(MAX(LENGTH(temp_txt)), 0),
             NVL(MAX(LENGTH(search_txt)), 0),
             NVL(MAX(LENGTH(cpuio_txt)), 0),
             NVL(MAX(LENGTH(proj_txt)), 0)
           )
         ) AS w_op,
         LEAST(120, GREATEST(LENGTH('Name'), NVL(MAX(LENGTH(name_txt)), 0))) AS w_name,
         GREATEST(LENGTH('Rows'), NVL(MAX(LENGTH(TO_CHAR(cardinality))), 0)) AS w_rows,
         GREATEST(LENGTH('Bytes'), NVL(MAX(LENGTH(TO_CHAR(bytes))), 0)) AS w_bytes,
         GREATEST(LENGTH('Cost'), NVL(MAX(LENGTH(TO_CHAR(cost))), 0)) AS w_cost,
         GREATEST(LENGTH('Time'), NVL(MAX(LENGTH(TO_CHAR(plan_time))), 0)) AS w_time
    FROM base
   GROUP BY phv
),
phvs AS (
  SELECT DISTINCT phv FROM base
),
lines AS (
  SELECT p.phv,
         0 AS sek,
         0 AS sid,
         '============================================================================' AS plan_line
    FROM phvs p
  UNION ALL
  SELECT p.phv, 1, 0,
         'Plan Hash Value: ' || TO_CHAR(p.phv)
    FROM phvs p
  UNION ALL
  SELECT p.phv, 2, 0,
         '============================================================================'
    FROM phvs p
  UNION ALL
  SELECT p.phv, 4, 0,
         '|' || LPAD('Id', w.w_id) || '|' ||
         LPAD('Pid', w.w_pid) || '|' ||
         LPAD('Ord', w.w_ord) || '|' ||
         RPAD('Operation', w.w_op) || '|' ||
         RPAD('Name', w.w_name) || '|' ||
         RPAD('Rows', w.w_rows) || '|' ||
         RPAD('Bytes', w.w_bytes) || '|' ||
         RPAD('Cost', w.w_cost) || '|' ||
         RPAD('Time', w.w_time) || '|'
    FROM phvs p
    JOIN w ON w.phv = p.phv
  UNION ALL
  SELECT p.phv, 5, 0,
         '|' || LPAD('-', w.w_id, '-') || '|' ||
         LPAD('-', w.w_pid, '-') || '|' ||
         LPAD('-', w.w_ord, '-') || '|' ||
         RPAD('-', w.w_op, '-') || '|' ||
         RPAD('-', w.w_name, '-') || '|' ||
         RPAD('-', w.w_rows, '-') || '|' ||
         RPAD('-', w.w_bytes, '-') || '|' ||
         RPAD('-', w.w_cost, '-') || '|' ||
         RPAD('-', w.w_time, '-') || '|'
    FROM phvs p
    JOIN w ON w.phv = p.phv
  UNION ALL
  SELECT b.phv, 6, b.id * 20,
         '|' || LPAD(TO_CHAR(b.id), w.w_id) || '|' ||
         LPAD(NVL(TO_CHAR(b.parent_id), ' '), w.w_pid) || '|' ||
         LPAD(TO_CHAR(b.id), w.w_ord) || '|' ||
         RPAD(SUBSTR(NVL(b.op_txt, ' '), 1, w.w_op), w.w_op) || '|' ||
         RPAD(SUBSTR(NVL(b.name_txt, ' '), 1, w.w_name), w.w_name) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.cardinality), ' '), 1, w.w_rows), w.w_rows) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.bytes), ' '), 1, w.w_bytes), w.w_bytes) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.cost), ' '), 1, w.w_cost), w.w_cost) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.plan_time), ' '), 1, w.w_time), w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 1,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.access_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.access_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 2,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.filter_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.filter_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 3,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.part_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.part_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 4,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.other_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.other_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 5,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.temp_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.temp_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 6,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.search_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.search_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 7,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.cpuio_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.cpuio_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 8,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.proj_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.proj_txt IS NOT NULL
  UNION ALL
  SELECT p.phv, 7, 0,
         '============================================================================'
    FROM phvs p
),
empty_msg AS (
  SELECT CAST(NULL AS NUMBER) AS phv,
         0 AS sek,
         0 AS sid,
         'No plan found in V$SQL_PLAN for sql_id=&&sqlid' AS plan_line
    FROM dual
   WHERE NOT EXISTS (SELECT 1 FROM base)
)
SELECT plan_line
  FROM (
        SELECT phv, sek, sid, plan_line FROM lines
        UNION ALL
        SELECT phv, sek, sid, plan_line FROM empty_msg
       )
 ORDER BY phv NULLS LAST, sek, sid
/


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from v$sqlarea                |
PROMPT +------------------------------------------------------------------------+
PROMPT

col  EXEC                   for   a8
col  CPU_P_E                for   a10
col  ELA_P_E                for   a10
col  DISK_P_E               for   a10
col  GET_P_E                for   a10
col  ROWS_P_E               for   a10
col  APP_W_P                for   a10
col  CLU_W_P                for   a10
col  IO_W_P                 for   a10
col  ROWS_P_F               for   a10
col  CON_W_P                for   a10
col  PLSQL_W_P              for   a10
col  OUTLINE                for   a20
col  F_L_TIME               for   a15
col  APP_P_E                for   a10
col  CON_P_E                for   a10
col  USERNAME               for   a15
col  C                      for   a3
col  PHV                    for   a12
col  IOW_P_E                for   a10
col  WRITE_P_E              for   a10
col  i                      for   a1
col  SORTS_P_E              for   a10
col  SEGMENT_NAME           for   a25

SELECT PLAN_HASH_VALUE||'' PHV,
        CASE
        WHEN EXECUTIONS < 1000 THEN TO_CHAR(EXECUTIONS)
        WHEN EXECUTIONS < 10000 THEN TO_CHAR(ROUND(EXECUTIONS / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(EXECUTIONS / 10000, 2)) || 'W'
        END AS EXEC,
       CASE
        WHEN CPU_TIME IS NULL THEN NULL
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
        END AS CPU_P_E,
       CASE
        WHEN ELAPSED_TIME IS NULL THEN NULL
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
        END AS ELA_P_E,
       CASE
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
        END AS DISK_P_E,
       CASE
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS GET_P_E,
       CASE
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS ROWS_P_E,
       CASE
        WHEN fetches/ DECODE(executions, 0, 1, executions) < 1000 THEN TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions),2))
        WHEN fetches / DECODE(executions, 0, 1, executions) < 10000 THEN TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions) / 10000, 2)) || 'W'
        END AS ROWS_P_F,
      CASE
        WHEN APPLICATION_WAIT_TIME IS NULL THEN NULL
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS APP_W_P,
        CASE
        WHEN CONCURRENCY_WAIT_TIME IS NULL THEN NULL
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CON_W_P,
         case
               WHEN CLUSTER_WAIT_TIME IS NULL THEN NULL
               WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CLU_W_P,
               CASE
        WHEN USER_IO_WAIT_TIME IS NULL THEN NULL
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS IO_W_P,
    CASE
        WHEN PLSQL_EXEC_TIME IS NULL THEN NULL
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS PLSQL_W_P,
    CAST(NULL AS VARCHAR(64)) AS outline
  FROM v$sqlarea
where sql_id = '&&sqlid';

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from v$sql                 |
PROMPT +------------------------------------------------------------------------+
PROMPT


SELECT
    CASE
        WHEN EXECUTIONS < 1000 THEN TO_CHAR(EXECUTIONS)
        WHEN EXECUTIONS < 10000 THEN TO_CHAR(ROUND(EXECUTIONS / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(EXECUTIONS / 10000, 2)) || 'W'
    END AS EXEC,
    PLAN_HASH_VALUE||'' PHV,
    child_number||'' AS c,
    PARSING_SCHEMA_NAME AS username,
      CASE
        WHEN CPU_TIME IS NULL THEN NULL
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CPU_P_E,
    CASE
        WHEN ELAPSED_TIME IS NULL THEN NULL
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS ELA_P_E,
    CASE
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS DISK_P_E,
    CASE
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS GET_P_E,
    CASE
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS ROWS_P_E,
    CASE
        WHEN ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES),2))
        WHEN ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) / 10000, 2)) || 'W'
    END AS ROWS_P_F,
  CASE
        WHEN APPLICATION_WAIT_TIME IS NULL THEN NULL
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS APP_P_E,
        CASE
        WHEN CONCURRENCY_WAIT_TIME IS NULL THEN NULL
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CON_P_E,
        CASE
        WHEN CLUSTER_WAIT_TIME IS NULL THEN NULL
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CLU_W_P,
        CASE
        WHEN USER_IO_WAIT_TIME IS NULL THEN NULL
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS IO_W_P,
        CASE
        WHEN PLSQL_EXEC_TIME IS NULL THEN NULL
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS PLSQL_W_P,
    SUBSTR(FIRST_LOAD_TIME, 6, 10) || '.' || SUBSTR(LAST_LOAD_TIME, 6, 10) AS f_l_time
FROM v$sql s
WHERE sql_id = '&&sqlid'
ORDER BY plan_hash_value;


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from awr (END_INTERVAL_TIME > SYSDATE-5)                  |
PROMPT +------------------------------------------------------------------------+
PROMPT

SELECT TO_CHAR (END_INTERVAL_TIME, 'dd hh24') end_time,
         TRIM (a.instance_number) i,
         a.parsing_schema_name as username,
         a.plan_hash_value||'' PHV,
      CASE
        WHEN executions_delta < 1000 THEN TO_CHAR(executions_delta)
        WHEN executions_delta < 10000 THEN TO_CHAR(ROUND(executions_delta / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(executions_delta / 10000, 2)) || 'W'
    END AS EXEC,
    CASE
        WHEN cpu_time_delta IS NULL THEN NULL
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CPU_P_E,
    CASE
        WHEN elapsed_time_delta IS NULL THEN NULL
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS ELA_P_E,
    CASE
        WHEN disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS DISK_P_E,
        CASE
        WHEN BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS GET_P_E,
    CASE
        WHEN rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS ROWS_P_E,
    CASE
        WHEN fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS ROWS_P_F,
    CASE
        WHEN direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS WRITE_P_E,
    CASE
        WHEN IOWAIT_DELTA IS NULL THEN NULL
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS IOW_P_E,
    -- CASE
    --     WHEN parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
    --     WHEN parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
    --     ELSE TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    -- END AS PARSE_P_E,
    CASE
        WHEN sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS SORTS_P_E,
    CASE
        WHEN apwait_delta IS NULL THEN NULL
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS APP_P_E,
    CASE
        WHEN ccwait_delta IS NULL THEN NULL
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CON_P_E,
    CASE
        WHEN clwait_delta IS NULL THEN NULL
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CLU_W_P,
    CASE
        WHEN plsexec_time_delta IS NULL THEN NULL
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS PLSQL_W_P
    FROM WRH$_SQLSTAT  a, WRM$_SNAPSHOT b
   WHERE     a.sql_id = '&&sqlid'
         AND a.snap_id = b.snap_id
         AND b.END_INTERVAL_TIME > SYSDATE - 5
         AND a.instance_number = b.instance_number
ORDER BY 1
/


prompt
prompt ****************************************************************************************
prompt OBJECT SIZE
prompt ****************************************************************************************
-- Object resolution: small v$sql_plan set -> tbl (index->table UNION table), then JOIN.
-- Avoid (owner,name) IN (UNION dba_indexes/dba_tables) semi-join explosion.
-- seg = [***]owner.name  (*** = table)

col seg                for   a50
col typ                for   a18
col sz                 for   a8

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
),
objs AS (
  SELECT owner, name AS segment_name FROM t
  UNION
  SELECT owner, table_name FROM tbl
)
SELECT CASE WHEN EXISTS (
              SELECT 1 FROM tbl tt
               WHERE tt.owner = b.owner AND tt.table_name = b.segment_name
            )
            THEN '***' ELSE '' END
       || b.owner || '.' || b.segment_name AS seg,
       b.segment_type AS typ,
       TRUNC(b.bytes / 1024 / 1024) || 'M' AS sz
  FROM (
        SELECT s.owner, s.segment_name, s.segment_type, SUM(s.bytes) AS bytes
          FROM dba_segments s
          JOIN objs o
            ON s.owner = o.owner
           AND s.segment_name = o.segment_name
         GROUP BY s.owner, s.segment_type, s.segment_name
       ) b
 ORDER BY b.owner, b.segment_name
/



prompt
prompt ****************************************************************************************
prompt TABLES
prompt ****************************************************************************************

col tab                for a40
col l_t                for a5
col degree             for a6
col part               for a4
col nrows              for a8
col blks               for a8
col eblks              for a6
col avg_sp             for a6
col avg_rlen           for a6
col blk_mb             for a8
col avg_mb             for a8
col stale              for a5
col last_analyzed      for a19

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.owner || '.' || a.table_name AS tab,
       a.logging || '.' || a.temporary AS l_t,
       LTRIM(a.degree) AS degree,
       a.partitioned AS part,
       CASE
         WHEN a.num_rows IS NULL THEN NULL
         WHEN a.num_rows < 1000 THEN TO_CHAR(a.num_rows)
         WHEN a.num_rows < 1000000 THEN TO_CHAR(ROUND(a.num_rows / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(a.num_rows / 1000000, 2)) || 'M'
       END AS nrows,
       CASE
         WHEN a.blocks IS NULL THEN NULL
         WHEN a.blocks < 1000 THEN TO_CHAR(a.blocks)
         WHEN a.blocks < 1000000 THEN TO_CHAR(ROUND(a.blocks / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(a.blocks / 1000000, 2)) || 'M'
       END AS blks,
       CASE
         WHEN a.empty_blocks IS NULL THEN NULL
         WHEN a.empty_blocks < 1000 THEN TO_CHAR(a.empty_blocks)
         WHEN a.empty_blocks < 1000000 THEN TO_CHAR(ROUND(a.empty_blocks / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(a.empty_blocks / 1000000, 2)) || 'M'
       END AS eblks,
       b.avg_space || '' AS avg_sp,
       b.avg_row_len || '' AS avg_rlen,
       TRUNC((b.blocks * tp.block_size) / 1024 / 1024) || 'M' AS blk_mb,
       TRUNC((b.avg_row_len * b.num_rows) / 1024 / 1024) || 'M' AS avg_mb,
       b.stale_stats || '' AS stale,
       TO_CHAR(a.last_analyzed, 'yyyy-mm-dd hh24:mi:ss') AS last_analyzed
  FROM tbl x
  JOIN dba_tables a
    ON a.owner = x.owner AND a.table_name = x.table_name
  LEFT JOIN dba_tab_statistics b
    ON b.owner = a.owner
   AND b.table_name = a.table_name
   AND b.object_type = 'TABLE'
  LEFT JOIN dba_tablespaces tp
    ON tp.tablespace_name = a.tablespace_name
 ORDER BY a.owner, a.table_name
/



prompt
prompt ****************************************************************************************
prompt TABLE COLUMNS
prompt ****************************************************************************************
-- tab = owner.table; col_type = column_name(datatype(len)); counts use K/M units

col tab                for a40
col col_type           for a40
col ndist              for a8
col n                  for a1
col nnulls             for a8
col density            for a12
col nbucket            for a6
col avg_len            for a6
col sample             for a8
col hist               for a5
col last_analyzed      for a19

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.owner || '.' || a.table_name AS tab,
       a.column_name || '(' || a.data_type || '(' || a.data_length || '))' AS col_type,
       CASE
         WHEN b.num_distinct IS NULL THEN NULL
         WHEN b.num_distinct < 1000 THEN TO_CHAR(b.num_distinct)
         WHEN b.num_distinct < 1000000 THEN TO_CHAR(ROUND(b.num_distinct / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(b.num_distinct / 1000000, 2)) || 'M'
       END AS ndist,
       a.nullable || '' AS n,
       CASE
         WHEN b.num_nulls IS NULL THEN NULL
         WHEN b.num_nulls < 1000 THEN TO_CHAR(b.num_nulls)
         WHEN b.num_nulls < 1000000 THEN TO_CHAR(ROUND(b.num_nulls / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(b.num_nulls / 1000000, 2)) || 'M'
       END AS nnulls,
       TO_CHAR(b.density, 'FM999999999990.999999999999') AS density,
       CASE
         WHEN b.num_buckets IS NULL THEN NULL
         WHEN b.num_buckets < 1000 THEN TO_CHAR(b.num_buckets)
         WHEN b.num_buckets < 1000000 THEN TO_CHAR(ROUND(b.num_buckets / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(b.num_buckets / 1000000, 2)) || 'M'
       END AS nbucket,
       b.avg_col_len || '' AS avg_len,
       CASE
         WHEN b.sample_size IS NULL THEN NULL
         WHEN b.sample_size < 1000 THEN TO_CHAR(b.sample_size)
         WHEN b.sample_size < 1000000 THEN TO_CHAR(ROUND(b.sample_size / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(b.sample_size / 1000000, 2)) || 'M'
       END AS sample,
       SUBSTR(b.histogram, 1, 5) AS hist,
       TO_CHAR(b.last_analyzed, 'yyyy-mm-dd hh24:mi:ss') AS last_analyzed
  FROM tbl x
  JOIN dba_tab_cols a
    ON a.owner = x.owner AND a.table_name = x.table_name
  LEFT JOIN dba_tab_col_statistics b
    ON b.owner = a.owner
   AND b.table_name = a.table_name
   AND b.column_name = a.column_name
 ORDER BY a.owner, a.table_name, a.column_id
/



prompt
prompt ****************************************************************************************
prompt INDEX STATUS
prompt ****************************************************************************************

col idx                    for a50
col PARTITION_NAME         for a20
col SUBPARTITION_NAME      for a20
col status                 for a10

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
),
tt AS (
  SELECT i.owner,
         i.index_name,
         i.status,
         i.partitioned
    FROM dba_indexes i
    JOIN tbl x
      ON i.table_owner = x.owner
     AND i.table_name = x.table_name
   WHERE i.status NOT IN ('VALID')
)
SELECT owner || '.' || index_name AS idx,
       '' AS partition_name,
       '' AS subpartition_name,
       status
  FROM tt
 WHERE tt.partitioned = 'NO'
UNION ALL
SELECT p.index_owner || '.' || p.index_name AS idx,
       p.partition_name,
       '' AS subpartition_name,
       p.status
  FROM dba_ind_partitions p
  JOIN tt
    ON p.index_owner = tt.owner
   AND p.index_name = tt.index_name
 WHERE tt.partitioned = 'YES'
   AND p.status NOT IN ('USABLE')
UNION ALL
SELECT p.index_owner || '.' || p.index_name AS idx,
       p.partition_name,
       p.subpartition_name,
       p.status
  FROM dba_ind_subpartitions p
  JOIN tt
    ON p.index_owner = tt.owner
   AND p.index_name = tt.index_name
 WHERE tt.partitioned = 'YES'
   AND p.status NOT IN ('USABLE')
 ORDER BY 1, 2, 3, 4
/

prompt
prompt ****************************************************************************************
prompt INDEX INFO
prompt ****ucptdvs "UNIQUENESS COMPRESSION PARTITIONED TEMPORARY  VISIBILITY                "**
prompt ****************************************************************************************

col tab                for a40
col idx                for a64
col ucptv              for a6
col col_pos            for a28
col descend            for a4

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.table_owner || '.' || a.table_name AS tab,
       a.index_name AS idx,
          DECODE(a.uniqueness,  'UNIQUE', 'U',  'NONUNIQUE', 'N',  'O')
       || DECODE(a.compression, 'ENABLED', 'E',  'DISABLED', 'N',  'O')
       || DECODE(a.partitioned, 'YES', 'Y',  'NO', 'N',  'O')
       || DECODE(a.temporary,  'Y', 'Y',  'N', 'N',  'O')
       || DECODE(a.visibility, 'VISIBLE', 'V',  'INVISIBLE', 'I',  'O') AS ucptv,
       b.column_name || '(' || b.column_position || ')' AS col_pos,
       b.descend
  FROM tbl x
  JOIN dba_indexes a
    ON a.table_owner = x.owner
   AND a.table_name = x.table_name
  JOIN dba_ind_columns b
    ON a.owner = b.index_owner
   AND a.index_name = b.index_name
 ORDER BY a.table_owner, a.table_name, a.index_name, b.column_position
/


prompt
prompt ****************************************************************************************
prompt PARTITION INDEX
prompt ****************************************************************************************

col idx                for a50
col part_type          for a10
col subpart_type       for a10
col locality           for a10
col col_pos            for a28

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.owner || '.' || a.name AS idx,
       b.partitioning_type AS part_type,
       b.subpartitioning_type AS subpart_type,
       b.partition_count || '' AS part_cnt,
       b.partitioning_key_count || '' AS key_cnt,
       b.subpartitioning_key_count || '' AS subkey_cnt,
       b.locality,
       a.column_name || '(' || a.column_position || ')' AS col_pos
  FROM dba_part_key_columns a
  JOIN dba_part_indexes b
    ON a.owner = b.owner
   AND a.name = b.index_name
  JOIN dba_indexes i
    ON i.owner = b.owner
   AND i.index_name = b.index_name
  JOIN tbl x
    ON i.table_owner = x.owner
   AND i.table_name = x.table_name
 ORDER BY a.owner, a.name, a.column_position
/


prompt
prompt ****************************************************************************************
prompt PARTITION TABLE
prompt ****************************************************************************************

col tab                for a40
col part_type          for a10
col subpart_type       for a10
col col_pos            for a28

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT a.owner || '.' || a.name AS tab,
       b.partitioning_type AS part_type,
       b.subpartitioning_type AS subpart_type,
       b.partition_count || '' AS part_cnt,
       b.partitioning_key_count || '' AS key_cnt,
       b.subpartitioning_key_count || '' AS subkey_cnt,
       a.column_name || '(' || a.column_position || ')' AS col_pos
  FROM dba_part_key_columns a
  JOIN dba_part_tables b
    ON a.owner = b.owner
   AND a.name = b.table_name
  JOIN tbl x
    ON a.owner = x.owner
   AND a.name = x.table_name
 ORDER BY a.name, a.column_position
/



prompt
prompt ****************************************************************************************
prompt display every partition  info
prompt ****************************************************************************************

col tab                     for a40
col partition_name          for a20
col high_value              for a25
col ts                      for a15
col nrows                   for a8
col blks                    for a8
col t_size                  for a10
col eblks                   for a6
col last_analyzed           for a19
col avg_sp                  for a6
col spcnt                   for a5

WITH t AS (
  SELECT DISTINCT object_owner AS owner, object_name AS name
    FROM v$sql_plan
   WHERE sql_id = '&&sqlid'
     AND object_name IS NOT NULL
),
tbl AS (
  SELECT DISTINCT i.table_owner AS owner, i.table_name
    FROM t
    JOIN dba_indexes i ON i.owner = t.owner AND i.index_name = t.name
  UNION
  SELECT t.owner, t.name
    FROM t
    JOIN dba_tables dt ON dt.owner = t.owner AND dt.table_name = t.name
)
SELECT p.table_owner || '.' || p.table_name AS tab,
       p.partition_name,
       p.high_value,
       p.tablespace_name AS ts,
       CASE
         WHEN p.num_rows IS NULL THEN NULL
         WHEN p.num_rows < 1000 THEN TO_CHAR(p.num_rows)
         WHEN p.num_rows < 1000000 THEN TO_CHAR(ROUND(p.num_rows / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(p.num_rows / 1000000, 2)) || 'M'
       END AS nrows,
       CASE
         WHEN p.blocks IS NULL THEN NULL
         WHEN p.blocks < 1000 THEN TO_CHAR(p.blocks)
         WHEN p.blocks < 1000000 THEN TO_CHAR(ROUND(p.blocks / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(p.blocks / 1000000, 2)) || 'M'
       END AS blks,
       ROUND(p.blocks * 8 / 1024, 2) || 'KB' AS t_size,
       CASE
         WHEN p.empty_blocks IS NULL THEN NULL
         WHEN p.empty_blocks < 1000 THEN TO_CHAR(p.empty_blocks)
         WHEN p.empty_blocks < 1000000 THEN TO_CHAR(ROUND(p.empty_blocks / 1000, 1)) || 'K'
         ELSE TO_CHAR(ROUND(p.empty_blocks / 1000000, 2)) || 'M'
       END AS eblks,
       TO_CHAR(p.last_analyzed, 'yyyy-mm-dd hh24:mi:ss') AS last_analyzed,
       p.avg_space || '' AS avg_sp,
       SUBSTR(p.subpartition_count || '', 1, 5) AS spcnt
  FROM dba_tab_partitions p
  JOIN tbl x
    ON p.table_owner = x.owner
   AND p.table_name = x.table_name
 ORDER BY p.table_name, p.partition_position
/





"""


# ---------------------------------------------------------------------------
# Dual logging (yinstall / yashan_backup style): session terminal + debug file
# ---------------------------------------------------------------------------

_LOG = None
_LOG_LOCK = threading.Lock()


def format_log_line(level, msg):
    # type: (str, object) -> str
    """Return 'YYYY-MM-DD HH:MM:SS  LEVEL  message' with aligned LEVEL column."""
    ts = dt.datetime.now().strftime(LOG_LINE_TS)
    lv = (level or "INFO").upper()
    if len(lv) > LOG_LEVEL_WIDTH:
        lv = lv[:LOG_LEVEL_WIDTH]
    body = _strip_redundant_level_tag(msg)
    return "{0}  {1:<{w}}  {2}".format(ts, lv, body, w=LOG_LEVEL_WIDTH)


def _infer_err_level(msg):
    # type: (str) -> str
    s = str(msg).lstrip()
    if s.startswith("[WARN]") or s.upper().startswith("WARN"):
        return "WARN"
    if s.startswith("[ERROR]") or s.startswith("[JDBC-ERR]") or s.startswith("jdbc-err") or s.upper().startswith("ERROR"):
        return "ERROR"
    return "ERROR"


def _strip_redundant_level_tag(msg):
    # type: (object) -> str
    """Drop leading [WARN]/[ERROR]/... so LEVEL column is not duplicated."""
    s = str(msg).rstrip("\n")
    m = re.match(
        r"^\s*\[(?:WARN|ERROR|INFO|DEBUG|STEP|JDBC-ERR)\]\s*",
        s,
        flags=re.IGNORECASE,
    )
    if m:
        return s[m.end() :]
    return s


class DualLogger(object):
    """Session (terminal mirror) + debug (every background step)."""

    def __init__(self, run_id, session_path, debug_path):
        self.run_id = run_id
        self.session_path = session_path
        self.debug_path = debug_path
        self._lock = threading.Lock()
        self._session = open(session_path, "w")
        self._debug = open(debug_path, "w")

    @classmethod
    def new(cls, cmd, log_dir=DEFAULT_LOG_DIR):
        # type: (str, str) -> DualLogger
        now = dt.datetime.now()
        ts = now.strftime(LOG_TS_FMT)
        cmd_s = re.sub(r"[^a-zA-Z0-9_-]+", "_", (cmd or "run").lower()).strip("_") or "run"
        base = os.path.abspath(log_dir or DEFAULT_LOG_DIR)
        if not os.path.isdir(base):
            os.makedirs(base)
        session_path = os.path.join(base, "sql_collect_{0}_{1}.log".format(cmd_s, ts))
        debug_path = os.path.join(base, "sql_collect_{0}_debug_{1}.log".format(cmd_s, ts))
        lg = cls("{0}-{1}".format(cmd_s, ts), session_path, debug_path)
        banner = (
            "Version: {0}\nAuthor: {1}\nContact: {2}\n\n"
            "The log of current session can be found at:\n  {3}\n"
            "Debug log can be found at:\n  {4}\n"
        ).format(VERSION, APP_AUTHOR, APP_CONTACT or "-", session_path, debug_path)
        lg._write_raw(banner, level="INFO")
        lg.debug("logger init run_id={0} cmd={1}".format(lg.run_id, cmd_s))
        return lg

    def close(self):
        with self._lock:
            for fh in (self._session, self._debug):
                if fh and not fh.closed:
                    fh.flush()
                    fh.close()

    def _write_raw(self, text, level="INFO"):
        """Write multi-line banner-style text (no per-line level prefix on console)."""
        with self._lock:
            out = text if text.endswith("\n") else text + "\n"
            sys.stdout.write(out)
            sys.stdout.flush()
            if not self._session.closed:
                self._session.write(out)
                self._session.flush()
            if not self._debug.closed:
                for ln in out.splitlines():
                    if ln.strip():
                        self._debug.write(format_log_line(level, ln) + "\n")
                self._debug.flush()

    def _emit(self, level, msg, to_stderr=False, to_console=True, to_debug=True):
        # type: (str, object, bool, bool, bool) -> None
        line = format_log_line(level, msg)
        with self._lock:
            chunk = line + "\n"
            if to_console:
                if to_stderr:
                    sys.stderr.write(chunk)
                    sys.stderr.flush()
                else:
                    sys.stdout.write(chunk)
                    sys.stdout.flush()
                if not self._session.closed:
                    self._session.write(chunk)
                    self._session.flush()
            if to_debug and not self._debug.closed:
                self._debug.write(chunk)
                self._debug.flush()

    def term(self, msg, level="INFO"):
        """Terminal + session + debug with aligned level."""
        self._emit(level, msg, to_stderr=False, to_console=True, to_debug=True)

    def term_err(self, msg, level=None):
        lv = level or _infer_err_level(str(msg))
        self._emit(lv, msg, to_stderr=True, to_console=True, to_debug=True)

    def debug(self, msg):
        self._emit("DEBUG", msg, to_console=False, to_debug=True)

    def info(self, msg):
        self._emit("INFO", msg, to_console=False, to_debug=True)

    def warn(self, msg):
        self._emit("WARN", msg, to_console=False, to_debug=True)

    def step(self, name, detail=""):
        if detail:
            self._emit(
                "STEP",
                "=== [STEP] {0}: {1} ===".format(name, detail),
                to_console=False,
                to_debug=True,
            )
        else:
            self._emit(
                "STEP",
                "=== [STEP] {0} ===".format(name),
                to_console=False,
                to_debug=True,
            )

    def keyval(self, key, val):
        self._emit("DEBUG", "  {0}={1}".format(key, val), to_console=False, to_debug=True)

    def command_result(self, scope, cmd, rc, output, duration=None):
        self._emit("DEBUG", "{0} cmd={1}".format(scope, cmd), to_console=False, to_debug=True)
        dur = ""
        if duration is not None:
            dur = " duration={0:.3f}s".format(duration)
        self._emit(
            "DEBUG",
            "{0} exit_code={1}{2}".format(scope, rc, dur),
            to_console=False,
            to_debug=True,
        )
        text = str(output or "").rstrip("\n")
        if not text:
            self._emit(
                "DEBUG",
                "{0} output| (empty)".format(scope),
                to_console=False,
                to_debug=True,
            )
            return
        max_chars = 200000
        if len(text) > max_chars:
            head = text[:80000]
            tail = text[-40000:]
            text = head + "\n...[truncated {0} chars]...\n".format(len(text)) + tail
        for ln in text.split("\n"):
            self._emit(
                "DEBUG",
                "{0} out| {1}".format(scope, ln),
                to_console=False,
                to_debug=True,
            )


def init_logger(cmd, log_dir):
    # type: (str, object) -> DualLogger
    global _LOG
    with _LOG_LOCK:
        if _LOG is not None:
            try:
                _LOG.close()
            except Exception:
                pass
        _LOG = DualLogger.new(cmd, log_dir or DEFAULT_LOG_DIR)
        _LOG.debug("invocation| {0}".format(" ".join(sys.argv)))
        return _LOG


def close_logger():
    global _LOG
    with _LOG_LOCK:
        if _LOG is not None:
            try:
                _LOG.close()
            except Exception:
                pass
            _LOG = None


def get_log():
    return _LOG


def log_info(msg):
    """Terminal progress line (timestamp + INFO) + debug."""
    lg = _LOG
    if lg is not None:
        lg.term(msg, level="INFO")
    else:
        print(format_log_line("INFO", msg))


def log_warn(msg):
    """Terminal WARN + session + debug."""
    lg = _LOG
    if lg is not None:
        lg.term(msg, level="WARN")
    else:
        print(format_log_line("WARN", msg))


def log_dbg(msg):
    lg = _LOG
    if lg is not None:
        lg.debug(msg)


def log_step(name, detail=""):
    lg = _LOG
    if lg is not None:
        lg.step(name, detail)


def eprint(*args):
    msg = " ".join(str(a) for a in args)
    lg = _LOG
    if lg is not None:
        lg.term_err(msg)
    else:
        sys.stderr.write(format_log_line(_infer_err_level(msg), msg) + "\n")



def check_yasql(yasql_path):
    log_step("check_yasql", yasql_path)
    try:
        subprocess.Popen(
            [yasql_path, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).communicate(timeout=10)
        log_dbg("yasql version probe ok path={0}".format(yasql_path))
    except OSError:
        eprint("[ERROR] yasql not found: '{0}'".format(yasql_path))
        sys.exit(1)
    except Exception as exc:
        log_dbg("yasql version probe soft-fail: {0}".format(exc))


def yasql_run(sql_file, connect_str, yasql_path, timeout=YASQL_TIMEOUT):
    # type: (str, str, str, int) -> tuple
    """Run yasql @file; return (returncode, stdout_text)."""
    cmd = [yasql_path, "-S", connect_str, "@" + sql_file]
    cmd_disp = "{0} -S {1} @{2}".format(yasql_path, connect_str, sql_file)
    log_step("yasql_run", cmd_disp)
    t0 = time.time()
    try:
        proc = subprocess.Popen(
            cmd, stdin=DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        stdout, stderr = proc.communicate(timeout=timeout)
        out = stdout.decode("utf-8", errors="replace") if stdout else ""
        err = stderr.decode("utf-8", errors="replace") if stderr else ""
        if err.strip():
            out = out + ("\n" if out and not out.endswith("\n") else "") + err
        elapsed = time.time() - t0
        lg = _LOG
        if lg is not None:
            lg.command_result("yasql", cmd_disp, proc.returncode, out, elapsed)
        return proc.returncode, out
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except Exception:
            pass
        msg = "[ERROR] yasql timeout after {0}s\n".format(timeout)
        lg = _LOG
        if lg is not None:
            lg.command_result("yasql", cmd_disp, 124, msg, time.time() - t0)
        return 124, msg
    except OSError as exc:
        msg = "[ERROR] cannot run yasql: {0}\n".format(exc)
        lg = _LOG
        if lg is not None:
            lg.command_result("yasql", cmd_disp, 127, msg, time.time() - t0)
        return 127, msg


def write_temp_sql(content):
    # type: (str) -> str
    td = tempfile.NamedTemporaryFile(
        mode="w", suffix=".sql", delete=False, dir="/tmp", prefix="sql_collect_"
    )
    td.write(content)
    if not content.endswith("\n"):
        td.write("\n")
    td.close()
    log_dbg("write_temp_sql path={0} bytes={1}".format(td.name, os.path.getsize(td.name)))
    return td.name


def load_collected(path):
    # type: (str) -> set
    ids = set()
    if not os.path.isfile(path):
        return ids
    with open(path, "r") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            ids.add(line.split()[0])
    return ids


def append_collected(path, sql_id):
    # type: (str, str) -> None
    with open(path, "a") as fh:
        fh.write(sql_id + "\n")
    log_dbg("append_collected sql_id={0} path={1}".format(sql_id, path))


def _package_bind_empty_stats(pkg_dir):
    # type: (str) -> object
    """
    Return (n_binds, n_empty) for a replay package.
    None if binds files missing (treat as needs refresh).
    n_binds==0 means SQL has no bind slots (do not refresh).
    """
    bj = os.path.join(pkg_dir, "binds.json")
    bt = os.path.join(pkg_dir, "binds.txt")
    binds = []
    if os.path.isfile(bj):
        try:
            with open(bj, "r") as fh:
                arr = json.load(fh)
            if isinstance(arr, list):
                binds = arr
            else:
                return None
        except (OSError, ValueError, TypeError):
            return None
    elif os.path.isfile(bt):
        try:
            with open(bt, "r") as fh:
                for raw in fh:
                    line = raw.strip()
                    if not line or line.startswith("#"):
                        continue
                    # position|datatype|value (escaped)
                    parts = []
                    cur = []
                    esc = False
                    for ch in line:
                        if esc:
                            cur.append(ch)
                            esc = False
                            continue
                        if ch == "\\":
                            esc = True
                            continue
                        if ch == "|" and len(parts) < 2:
                            parts.append("".join(cur))
                            cur = []
                            continue
                        cur.append(ch)
                    parts.append("".join(cur))
                    if not parts or not parts[0].strip().isdigit():
                        continue
                    val = parts[2] if len(parts) > 2 else ""
                    binds.append({"value": unescape_pipe_field(val)})
        except OSError:
            return None
    else:
        return None
    n = len(binds)
    empty = 0
    for b in binds:
        val = b.get("value", "") if isinstance(b, dict) else ""
        if val is None:
            empty += 1
            continue
        s = str(val).strip()
        if s == "" or s == "\\N":
            empty += 1
    return n, empty


def sql_id_needs_bind_refresh(outdir, sql_id):
    # type: (str, str) -> bool
    """True if collected sql_id should be re-exported (empty binds or missing pkg)."""
    pkgs = list_replay_packages(outdir, [sql_id])
    if not pkgs:
        return True
    stats = _package_bind_empty_stats(pkgs[0])
    if stats is None:
        return True
    n_binds, n_empty = stats
    if n_binds == 0:
        return False
    return n_empty > 0


def _capture_bind_filled_count(sql_id, connect_str, yasql_path):
    # type: (str, str, str) -> object
    """
    Return number of bind capture rows with non-empty value_string for sql_id,
    or None if query failed. Used to skip useless BIND-REFRESH when capture
    still has nothing new.
    """
    sid = str(sql_id).replace("'", "''")
    sql = (
        "SET SERVEROUTPUT ON\n"
        "SET HEADING OFF\n"
        "DECLARE\n"
        "  v_n NUMBER := 0;\n"
        "BEGIN\n"
        "  BEGIN\n"
        "    SELECT COUNT(*) INTO v_n\n"
        "      FROM gv$sql_bind_capture\n"
        "     WHERE sql_id = '{0}'\n"
        "       AND last_captured IS NOT NULL\n"
        "       AND NVL(LENGTH(value_string), 0) > 0;\n"
        "  EXCEPTION WHEN OTHERS THEN\n"
        "    SELECT COUNT(*) INTO v_n\n"
        "      FROM v$sql_bind_capture\n"
        "     WHERE sql_id = '{0}'\n"
        "       AND last_captured IS NOT NULL\n"
        "       AND NVL(LENGTH(value_string), 0) > 0;\n"
        "  END;\n"
        "  DBMS_OUTPUT.PUT_LINE('BIND_FILLED=' || TO_CHAR(v_n));\n"
        "END;\n"
        "/\n"
        "EXIT;\n"
    ).format(sid)
    path = write_temp_sql(sql)
    try:
        rc, out = yasql_run(path, connect_str, yasql_path, timeout=60)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    for ln in (out or "").splitlines():
        s = ln.strip()
        if s.startswith("BIND_FILLED="):
            try:
                return int(s.split("=", 1)[1].strip())
            except ValueError:
                return None
    return None


def is_noise_text(sql_text):
    # type: (str) -> bool
    """Return True if SQL text should be skipped (noise)."""
    if sql_text is None:
        return True
    t = sql_text.strip()
    if not t:
        return True
    if PROBE_TAG in t:
        return True
    if len(t) < MIN_SQL_CHARS:
        return True
    u = t.upper()
    if u.startswith("ALTER SESSION"):
        return True
    if u.startswith("SET "):
        return True
    # tiny anonymous blocks
    compact = re.sub(r"\s+", " ", u).strip()
    if compact in ("BEGIN NULL; END;", "BEGIN END;", "BEGIN;", "END;"):
        return True
    if compact.startswith("BEGIN ") and len(compact) < 40:
        return True
    return False


def build_list_sql(use_gv):
    # type: (bool) -> str
    view = "gv$sql" if use_gv else "v$sql"
    # Emit one line per sql_id: sql_id|schema|len|snippet
    # Filter schemas in SQL; text noise filtered in Python.
    return (
        "SET SERVEROUTPUT ON\n"
        "SET HEADING OFF\n"
        "DECLARE\n"
        "  v_snip VARCHAR2(200);\n"
        "BEGIN\n"
        "  DBMS_OUTPUT.PUT_LINE('{start}');\n"
        "  FOR r IN (\n"
        "    SELECT sql_id,\n"
        "           MAX(parsing_schema_name) AS parsing_schema_name,\n"
        "           MAX(DBMS_LOB.GETLENGTH(sql_fulltext)) AS sql_len,\n"
        "           MAX(DBMS_LOB.SUBSTR(sql_fulltext, 180, 1)) AS snip\n"
        "      FROM {view}\n"
        "     WHERE parsing_schema_name IS NOT NULL\n"
        "       AND UPPER(parsing_schema_name) NOT IN ('SYS','SYSDBA')\n"
        "       AND sql_id IS NOT NULL\n"
        "       AND sql_fulltext NOT LIKE '%{tag}%'\n"
        "     GROUP BY sql_id\n"
        "  ) LOOP\n"
        "    v_snip := REPLACE(REPLACE(NVL(r.snip,''), CHR(10), ' '), '|', '/');\n"
        "    DBMS_OUTPUT.PUT_LINE(\n"
        "      r.sql_id || '|' || NVL(r.parsing_schema_name,'') || '|' ||\n"
        "      TO_CHAR(NVL(r.sql_len,0)) || '|' || v_snip);\n"
        "  END LOOP;\n"
        "  DBMS_OUTPUT.PUT_LINE('{end}');\n"
        "END;\n"
        "/\n"
        "EXIT;\n"
    ).format(start=MARK_START, end=MARK_END, view=view, tag=PROBE_TAG)


def build_active_sqlid_sql(use_gv):
    # type: (bool) -> str
    """活跃会话 sql_id, 跑得最久的优先 (与 Java CandidateService 对齐)."""
    view = "gv$session" if use_gv else "v$session"
    own = (
        "AND NOT (s.INST_ID = TO_NUMBER(SYS_CONTEXT('USERENV', 'INSTANCE'))\n"
        "             AND s.SID = TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')))\n"
        if use_gv
        else "AND s.SID <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))\n"
    )
    return (
        "SET SERVEROUTPUT ON\n"
        "SET HEADING OFF\n"
        "BEGIN\n"
        "  DBMS_OUTPUT.PUT_LINE('{start}');\n"
        "  FOR r IN (\n"
        "    SELECT s.sql_id\n"
        "      FROM {view} s\n"
        "     WHERE s.TYPE NOT IN ('BACKGROUND')\n"
        "       AND NVL(NULLIF(TRIM(s.status), ''), 'ACTIVE') NOT IN ('INACTIVE')\n"
        "       AND s.sql_id IS NOT NULL\n"
        "       AND LENGTH(TRIM(s.sql_id)) >= 5\n"
        "       {own}"
        "     ORDER BY s.exec_start_time ASC NULLS LAST, s.sql_id\n"
        "  ) LOOP\n"
        "    DBMS_OUTPUT.PUT_LINE(TRIM(r.sql_id));\n"
        "  END LOOP;\n"
        "  DBMS_OUTPUT.PUT_LINE('{end}');\n"
        "END;\n"
        "/\n"
        "EXIT;\n"
    ).format(start=MARK_START, end=MARK_END, view=view, own=own)


def list_active_sqlids(connect_str, yasql_path):
    # type: (str, str) -> list
    """Return ordered unique active-session sql_ids (longest-running first)."""
    out_ids = []
    seen = set()
    for use_gv in (True, False):
        path = write_temp_sql(build_active_sqlid_sql(use_gv))
        try:
            rc, out = yasql_run(path, connect_str, yasql_path, timeout=60)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        if MARK_START not in out:
            if use_gv:
                continue
            return out_ids
        in_mark = False
        for ln in out.splitlines():
            s = ln.strip()
            if s == MARK_START:
                in_mark = True
                continue
            if s == MARK_END:
                break
            if not in_mark or not s or len(s) < 5:
                continue
            if s in seen:
                continue
            seen.add(s)
            out_ids.append(s)
        if out_ids:
            log_dbg(
                "active session sql_ids={0} source={1}".format(
                    len(out_ids), "gv$session" if use_gv else "v$session"
                )
            )
            return out_ids
    return out_ids


def _lookup_one_candidate(connect_str, yasql_path, sql_id):
    # type: (str, str, str) -> dict
    """Fetch one sql_id from gv$/v$sql for active-first fill-in."""
    for use_gv in (True, False):
        view = "gv$sql" if use_gv else "v$sql"
        body = (
            "SET SERVEROUTPUT ON\n"
            "SET HEADING OFF\n"
            "DECLARE\n"
            "  v_snip VARCHAR2(200);\n"
            "BEGIN\n"
            "  DBMS_OUTPUT.PUT_LINE('{start}');\n"
            "  FOR r IN (\n"
            "    SELECT sql_id,\n"
            "           MAX(parsing_schema_name) AS parsing_schema_name,\n"
            "           MAX(DBMS_LOB.GETLENGTH(sql_fulltext)) AS sql_len,\n"
            "           MAX(DBMS_LOB.SUBSTR(sql_fulltext, 180, 1)) AS snip\n"
            "      FROM {view}\n"
            "     WHERE sql_id = '{sid}'\n"
            "       AND parsing_schema_name IS NOT NULL\n"
            "       AND UPPER(parsing_schema_name) NOT IN ('SYS','SYSDBA')\n"
            "       AND (sql_fulltext IS NULL OR sql_fulltext NOT LIKE '%{tag}%')\n"
            "     GROUP BY sql_id\n"
            "  ) LOOP\n"
            "    v_snip := REPLACE(REPLACE(NVL(r.snip,''), CHR(10), ' '), '|', '/');\n"
            "    DBMS_OUTPUT.PUT_LINE(\n"
            "      r.sql_id || '|' || NVL(r.parsing_schema_name,'') || '|' ||\n"
            "      TO_CHAR(NVL(r.sql_len,0)) || '|' || v_snip);\n"
            "  END LOOP;\n"
            "  DBMS_OUTPUT.PUT_LINE('{end}');\n"
            "END;\n"
            "/\n"
            "EXIT;\n"
        ).format(start=MARK_START, end=MARK_END, view=view, sid=sql_id.replace("'", "''"), tag=PROBE_TAG)
        path = write_temp_sql(body)
        try:
            rc, out = yasql_run(path, connect_str, yasql_path, timeout=60)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        if MARK_START not in out:
            continue
        in_mark = False
        for ln in out.splitlines():
            s = ln.strip()
            if s == MARK_START:
                in_mark = True
                continue
            if s == MARK_END:
                break
            if not in_mark or "|" not in s:
                continue
            parts = s.split("|", 3)
            if len(parts) < 3:
                continue
            sid = parts[0].strip()
            schema = parts[1].strip()
            try:
                sql_len = int(parts[2].strip() or "0")
            except ValueError:
                sql_len = 0
            snip = parts[3] if len(parts) > 3 else ""
            if not sid or len(sid) < 5:
                continue
            if schema.upper() in EXCLUDE_SCHEMAS:
                continue
            if sql_len < MIN_SQL_CHARS:
                continue
            if is_noise_text(snip):
                continue
            return {
                "sql_id": sid,
                "schema": schema,
                "sql_len": sql_len,
                "snip": snip,
            }
    return None


def prioritize_active_candidates(candidates, active_ids, connect_str, yasql_path):
    # type: (list, list, str, str) -> list
    if not active_ids:
        return candidates
    by_id = {}
    for item in candidates:
        sid = item.get("sql_id")
        if sid:
            by_id[sid] = item
    out = []
    seen = set()
    for sid in active_ids:
        if not sid or sid in seen:
            continue
        item = by_id.get(sid)
        if item is None:
            item = _lookup_one_candidate(connect_str, yasql_path, sid)
            if item is None:
                continue
            log_dbg("active sql_id not in pool; added {0} schema={1}".format(
                sid, item.get("schema", "")
            ))
        out.append(item)
        seen.add(sid)
    for item in candidates:
        sid = item.get("sql_id")
        if not sid or sid in seen:
            continue
        out.append(item)
        seen.add(sid)
    return out


def list_candidate_sqlids(connect_str, yasql_path):
    # type: (str, str) -> list
    """Return list of dicts: sql_id, schema, sql_len, snip (noise-filtered).

    Active-session sql_ids are placed first (longest-running first).
    """
    candidates = []
    for use_gv in (True, False):
        path = write_temp_sql(build_list_sql(use_gv))
        try:
            rc, out = yasql_run(path, connect_str, yasql_path, timeout=120)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        if MARK_START not in out:
            if use_gv:
                eprint("[WARN] gv$sql list failed or empty markers; try v$sql")
                continue
            eprint("[ERROR] failed to list sql_id from v$sql")
            eprint(out[-2000:] if out else "(no output)")
            return []
        in_mark = False
        for ln in out.splitlines():
            s = ln.strip()
            if s == MARK_START:
                in_mark = True
                continue
            if s == MARK_END:
                break
            if not in_mark or not s or "|" not in s:
                continue
            parts = s.split("|", 3)
            if len(parts) < 3:
                continue
            sql_id = parts[0].strip()
            schema = parts[1].strip()
            try:
                sql_len = int(parts[2].strip() or "0")
            except ValueError:
                sql_len = 0
            snip = parts[3] if len(parts) > 3 else ""
            if not sql_id or len(sql_id) < 5:
                continue
            if schema.upper() in EXCLUDE_SCHEMAS:
                continue
            if sql_len < MIN_SQL_CHARS:
                continue
            if is_noise_text(snip):
                continue
            candidates.append(
                {
                    "sql_id": sql_id,
                    "schema": schema,
                    "sql_len": sql_len,
                    "snip": snip,
                }
            )
        active_ids = list_active_sqlids(connect_str, yasql_path)
        ordered = prioritize_active_candidates(
            candidates, active_ids, connect_str, yasql_path
        )
        active_first = 0
        for item in ordered:
            if item.get("sql_id") in active_ids:
                active_first += 1
            else:
                break
        log_info(
            "candidates={0} active_session_sql={1} active_first={2}".format(
                len(ordered), len(active_ids), active_first
            )
        )
        return ordered
    return []


def run_sql_report(sql_id, connect_str, yasql_path):
    # type: (str, str, str) -> tuple
    """Execute embedded sql report for one sql_id. Return (ok, output_text)."""
    # DEFINE before report body (uses &&sqlid); VERIFY OFF hides old/new substitution spam
    body = (
        "SET SERVEROUTPUT ON\n"
        "SET HEADING ON\n"
        "SET VERIFY OFF\n"
        "DEFINE sqlid={0}\n"
        "{1}\n"
        "EXIT;\n"
    ).format(sql_id, EMBEDDED_SQL_REPORT)
    path = write_temp_sql(body)
    try:
        rc, out = yasql_run(path, connect_str, yasql_path, timeout=YASQL_TIMEOUT)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    ok = rc == 0 and "===== ORIGINAL SQL =====" in out
    if not ok and rc == 0 and "No SQL found in V$SQL" in out:
        ok = False
    return ok, out


def collect_one(item, outdir, collected_path, connect_str, yasql_path, skip_replay_export=False):
    # type: (dict, str, str, str, str, bool) -> bool
    sql_id = item["sql_id"]
    out_file = os.path.join(outdir, sql_id + ".txt")
    log_info(
        "new sql_id={0} schema={1} len={2}".format(
            sql_id, item.get("schema", ""), item.get("sql_len", 0)
        )
    )
    log_step("collect_one", sql_id)
    ok, out = run_sql_report(sql_id, connect_str, yasql_path)
    try:
        with open(out_file, "w") as fh:
            fh.write(out if out else "")
            if not out.endswith("\n"):
                fh.write("\n")
    except OSError as exc:
        eprint("[ERROR] write {0}: {1}".format(out_file, exc))
        return False
    if ok:
        log_info(
            "new done sql_id={0} report={1} ({2} bytes)".format(
                sql_id, out_file, os.path.getsize(out_file)
            )
        )
        if not skip_replay_export:
            if not export_replay_package(
                sql_id, outdir, connect_str, yasql_path, kind="NEW"
            ):
                eprint(
                    "[WARN] report OK but replay export failed for {0}; "
                    "not marked collected (will retry next round)".format(sql_id)
                )
                return False
        append_collected(collected_path, sql_id)
        return True
    eprint(
        "[WARN] report incomplete for {0}; saved raw output, not marked collected".format(
            sql_id
        )
    )
    return False


def resolve_loop(interval, count):
    # type: (object, object) -> tuple
    """
    Return (rounds, sleep_sec).
    rounds: int or None (None = infinite)
    sleep_sec: int or None (None = no sleep / single)
    """
    if interval is None and count is None:
        return 1, None
    if count is not None and interval is None:
        interval = DEFAULT_INTERVAL_WITH_COUNT
    if interval is not None and count is None:
        return None, int(interval)
    return int(count), int(interval)


def run_round(args, collected_path):
    # type: (object, str) -> tuple
    """Return (ok_n, fail_n, backup_ok)."""
    backup_ok = True
    backup_new_ids = []
    if not getattr(args, "skip_backup", False):
        backup_ok, backup_new_ids = run_backup_incremental(
            args.connect, args.yasql
        )
        if not backup_ok:
            eprint("[WARN] backup step failed; continue report collect")
    if getattr(args, "backup_only", False):
        for sid in backup_new_ids:
            log_dbg("backup-new sql_id={0}".format(sid))
        log_info(
            "backup-only done backup_new={0}".format(len(backup_new_ids))
        )
        if not backup_ok:
            eprint("[ERROR] backup-only failed")
            return 0, 1, False
        return 0, 0, True

    collected = load_collected(collected_path)
    items = list_candidate_sqlids(args.connect, args.yasql)
    new_items = [x for x in items if x["sql_id"] not in collected]
    refresh_items = []
    if not getattr(args, "skip_replay_export", False):
        refresh_items = [
            x
            for x in items
            if x["sql_id"] in collected
            and sql_id_needs_bind_refresh(args.outdir, x["sql_id"])
        ]

    log_dbg(
        "round collected={0} candidates={1} backup_new={2} collect_new={3} "
        "refresh={4}".format(
            len(collected),
            len(items),
            len(backup_new_ids),
            len(new_items),
            len(refresh_items),
        )
    )
    for sid in backup_new_ids:
        log_dbg("backup-new sql_id={0}".format(sid))

    ok_n = 0
    fail_n = 0
    refresh_skip = 0
    refresh_do = 0
    collect_new_ok = 0
    for item in new_items:
        if collect_one(
            item,
            args.outdir,
            collected_path,
            args.connect,
            args.yasql,
            skip_replay_export=getattr(args, "skip_replay_export", False),
        ):
            ok_n += 1
            collect_new_ok += 1
        else:
            fail_n += 1
    for item in refresh_items:
        sid = item["sql_id"]
        pkgs = list_replay_packages(args.outdir, [sid])
        pkg_filled = 0
        if pkgs:
            st = _package_bind_empty_stats(pkgs[0])
            if st is not None:
                n_binds, n_empty = st
                pkg_filled = max(0, n_binds - n_empty)
        # Missing package always refresh; otherwise only if capture has more filled values
        if pkgs:
            cap_filled = _capture_bind_filled_count(sid, args.connect, args.yasql)
            if cap_filled is not None and cap_filled <= pkg_filled:
                refresh_skip += 1
                log_dbg(
                    "refresh skip sql_id={0} pkg_filled={1} capture_filled={2}".format(
                        sid, pkg_filled, cap_filled
                    )
                )
                continue
        log_dbg(
            "refresh sql_id={0} schema={1}".format(sid, item.get("schema", ""))
        )
        log_step("bind_refresh", sid)
        refresh_do += 1
        if export_replay_package(
            sid, args.outdir, args.connect, args.yasql, kind="REFRESH"
        ):
            ok_n += 1
        else:
            fail_n += 1
            eprint("[WARN] refresh export failed for {0}".format(sid))
    if not backup_ok:
        fail_n += 1
    log_dbg(
        "round done backup_new={0} collect_new={1} refresh_export={2} "
        "refresh_skip={3} fail={4}".format(
            len(backup_new_ids),
            collect_new_ok,
            refresh_do,
            refresh_skip,
            fail_n,
        )
    )
    return ok_n, fail_n, backup_ok


# ---------------------------------------------------------------------------
# Replay export (files + SYS.HTZ_SQL_REPLAY_PKG) and JDBC replay
# ---------------------------------------------------------------------------

# Minimal Java helper: file / gv$ / HTZ_SQL_REPLAY_PKG sources; binds file: position|datatype|value
REPLAY_JDBC_JAVA = r"""
import java.io.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.sql.*;
import java.util.*;
import java.util.regex.*;

public class SqlReplayJdbc {
  static String readFile(String path) throws IOException {
    byte[] b = Files.readAllBytes(Paths.get(path));
    return new String(b, StandardCharsets.UTF_8);
  }

  static String readClob(Clob c) throws Exception {
    if (c == null) return "";
    Reader r = c.getCharacterStream();
    StringBuilder sb = new StringBuilder();
    char[] buf = new char[8192];
    int n;
    while ((n = r.read(buf)) >= 0) sb.append(buf, 0, n);
    r.close();
    return sb.toString();
  }

  static String[] splitPipeEscaped(String ln, int maxParts) {
    ArrayList<String> parts = new ArrayList<String>();
    StringBuilder cur = new StringBuilder();
    boolean esc = false;
    for (int i = 0; i < ln.length(); i++) {
      char c = ln.charAt(i);
      if (esc) { cur.append(c); esc = false; continue; }
      if (c == '\\') { esc = true; continue; }
      if (c == '|' && parts.size() < maxParts - 1) {
        parts.add(cur.toString());
        cur.setLength(0);
        continue;
      }
      cur.append(c);
    }
    parts.add(cur.toString());
    return parts.toArray(new String[0]);
  }

  static List<String[]> readBinds(String path) throws IOException {
    List<String[]> out = new ArrayList<String[]>();
    if (path == null || path.isEmpty() || !Files.exists(Paths.get(path))) {
      return out;
    }
    for (String ln : readFile(path).split("\n", -1)) {
      if (ln.isEmpty() || ln.startsWith("#")) continue;
      String[] p = splitPipeEscaped(ln, 3);
      if (p.length < 1) continue;
      out.add(new String[] {
        p[0].trim(),
        p.length > 1 ? p[1].trim() : "VARCHAR2",
        p.length > 2 ? p[2] : ""
      });
    }
    return out;
  }

  static String jsonUnescape(String s) {
    if (s == null) return "";
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      if (c == '\\' && i + 1 < s.length()) {
        char n = s.charAt(++i);
        if (n == 'n') sb.append('\n');
        else if (n == 'r') sb.append('\r');
        else if (n == 't') sb.append('\t');
        else sb.append(n);
      } else sb.append(c);
    }
    return sb.toString();
  }

  static String jsonField(String obj, String key) {
    Pattern pStr = Pattern.compile(
      "\\\"" + key + "\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"\\\\])*)\\\"");
    Matcher m = pStr.matcher(obj);
    if (m.find()) return jsonUnescape(m.group(1));
    Pattern pNum = Pattern.compile("\\\"" + key + "\\\"\\s*:\\s*(-?\\d+)");
    m = pNum.matcher(obj);
    if (m.find()) return m.group(1);
    Pattern pNull = Pattern.compile("\\\"" + key + "\\\"\\s*:\\s*null");
    if (pNull.matcher(obj).find()) return null;
    return "";
  }

  static List<String[]> parseBindsJson(String json) {
    List<String[]> out = new ArrayList<String[]>();
    if (json == null || json.trim().isEmpty() || json.trim().equals("[]")) return out;
    Matcher om = Pattern.compile("\\{([^{}]*)\\}").matcher(json);
    while (om.find()) {
      String obj = om.group(0);
      String pos = jsonField(obj, "position");
      if (pos == null || pos.isEmpty()) continue;
      String dt = jsonField(obj, "datatype");
      if (dt == null) dt = "";
      String val = jsonField(obj, "value");
      if (val == null) val = "";
      out.add(new String[] { pos, dt, val });
    }
    return out;
  }

  static int nullSqlType(String dt) {
    String u = dt == null ? "" : dt.toUpperCase(Locale.ROOT);
    if (u.contains("NUMBER") || u.contains("DECIMAL") || u.contains("INT")
        || u.contains("FLOAT") || u.contains("DOUBLE") || u.contains("BINARY_")) {
      return Types.NUMERIC;
    }
    if (u.contains("DATE") || u.contains("TIMESTAMP") || u.contains("TIME")) {
      return Types.TIMESTAMP;
    }
    return Types.VARCHAR;
  }

  static void bindOne(PreparedStatement ps, int idx, String dt, String val) throws SQLException {
    String u = dt == null ? "" : dt.toUpperCase(Locale.ROOT);
    if (val == null || val.isEmpty() || val.equals("\\N")) {
      ps.setNull(idx, nullSqlType(dt));
      return;
    }
    if (u.contains("NUMBER") || u.contains("DECIMAL") || u.contains("INT")
        || u.contains("FLOAT") || u.contains("DOUBLE") || u.contains("BINARY_")) {
      try {
        ps.setBigDecimal(idx, new BigDecimal(val.trim()));
        return;
      } catch (Exception e) {
        ps.setString(idx, val);
        return;
      }
    }
    if (u.contains("DATE") || u.contains("TIMESTAMP") || u.contains("TIME")) {
      String t = val.trim();
      // Common captured forms: yyyy-mm-dd[ hh:mm:ss[.fff]] / yyyy/mm/dd ...
      String[] patterns = new String[] {
        "yyyy-MM-dd HH:mm:ss.SSS",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
        "yyyy/MM/dd HH:mm:ss",
        "yyyy/MM/dd",
        "dd-MMM-yy",
        "dd-MMM-yyyy"
      };
      for (int i = 0; i < patterns.length; i++) {
        try {
          java.text.SimpleDateFormat sdf = new java.text.SimpleDateFormat(patterns[i], Locale.US);
          sdf.setLenient(false);
          java.util.Date d = sdf.parse(t);
          if (u.contains("DATE") && !u.contains("TIMESTAMP") && patterns[i].equals("yyyy-MM-dd")) {
            ps.setDate(idx, new java.sql.Date(d.getTime()));
          } else {
            ps.setTimestamp(idx, new Timestamp(d.getTime()));
          }
          return;
        } catch (Exception e) { /* try next */ }
      }
      try {
        ps.setTimestamp(idx, Timestamp.valueOf(t.replace('T', ' ').substring(0, Math.min(t.length(), 23))));
        return;
      } catch (Exception e) {
        ps.setString(idx, val);
        return;
      }
    }
    ps.setString(idx, val);
  }

  static String stripSqlLead(String sql) {
    if (sql == null) return "";
    String s = sql;
    // remove /* */ and -- line comments (best-effort)
    s = s.replaceAll("/\\*[\\s\\S]*?\\*/", " ");
    StringBuilder sb = new StringBuilder();
    for (String ln : s.split("\n", -1)) {
      int p = ln.indexOf("--");
      if (p >= 0) ln = ln.substring(0, p);
      sb.append(ln).append('\n');
    }
    s = sb.toString().trim();
    while (s.startsWith("(")) s = s.substring(1).trim();
    return s;
  }

  static String classifySql(String sql) {
    String s = stripSqlLead(sql);
    if (s.isEmpty()) return "empty";
    String u = s.toUpperCase(Locale.ROOT);
    if (u.startsWith("WITH")) {
      Matcher m = Pattern.compile("\\b(INSERT|UPDATE|DELETE|MERGE|CREATE|ALTER|DROP|TRUNCATE)\\b").matcher(u);
      if (m.find()) {
        String k = m.group(1);
        if ("CREATE".equals(k) || "ALTER".equals(k) || "DROP".equals(k) || "TRUNCATE".equals(k)) {
          return "ddl";
        }
        return "dml";
      }
      return "query";
    }
    if (u.startsWith("SELECT") || u.startsWith("EXPLAIN")) return "query";
    if (u.startsWith("INSERT") || u.startsWith("UPDATE") || u.startsWith("DELETE") || u.startsWith("MERGE")) return "dml";
    if (u.startsWith("CREATE") || u.startsWith("ALTER") || u.startsWith("DROP") || u.startsWith("TRUNCATE")
        || u.startsWith("GRANT") || u.startsWith("REVOKE") || u.startsWith("COMMENT") || u.startsWith("ANALYZE")
        || u.startsWith("FLASHBACK") || u.startsWith("PURGE") || u.startsWith("RENAME")) return "ddl";
    if (u.startsWith("BEGIN") || u.startsWith("DECLARE") || u.startsWith("CALL") || u.startsWith("EXEC")) return "plsql";
    return "other";
  }

  static boolean execSql(Connection c, String schema, String sql, List<String[]> binds, String mode, boolean force) throws Exception {
    return execSql(c, schema, sql, binds, mode, force, null);
  }

  static boolean execSql(Connection c, String schema, String sql, List<String[]> binds, String mode, boolean force, String loginUser) throws Exception {
    System.out.println("replay sql-chars=" + sql.length());
    System.out.println("replay binds=" + binds.size());
    System.out.println("replay schema=" + (schema == null ? "" : schema));
    String kind = classifySql(sql);
    System.out.println("replay sql-kind=" + kind);
    int empty = 0;
    for (String[] b : binds) {
      if (b[2] == null || b[2].isEmpty()) empty++;
    }
    if (empty > 0) System.out.println("replay warn empty_bind_values=" + empty);
    if (!force && !"query".equals(kind)) {
      System.out.println("replay blocked kind=" + kind + " (query-only; pass --force to allow)");
      if ("dry".equalsIgnoreCase(mode)) {
        System.out.println("replay dry-run-ok");
        return true;
      }
      System.out.println("replay fail blocked non-query without --force");
      return false;
    }
    if ("dry".equalsIgnoreCase(mode)) {
      System.out.println("replay dry-run-ok");
      return true;
    }
    // Already connected as parsing_schema (or fallback). Keep CURRENT_SCHEMA aligned
    // only when login user differs; same-user SET often lacks privilege on YashanDB.
    if (schema != null && !schema.isEmpty() && !"NULL".equalsIgnoreCase(schema)) {
      String login = loginUser;
      if ((login == null || login.isEmpty()) && c != null) {
        try { login = c.getMetaData().getUserName(); } catch (Exception e) { /* ignore */ }
      }
      if (login != null && login.equalsIgnoreCase(schema)) {
        System.out.println("replay schema-skip same_as_login=" + schema);
      } else {
        try {
          Statement st = c.createStatement();
          String q = schema.replace("\"", "\"\"");
          st.execute("ALTER SESSION SET CURRENT_SCHEMA = \"" + q + "\"");
          st.close();
          System.out.println("replay schema-set=" + schema);
        } catch (Exception e) {
          System.out.println("replay warn set_schema " + e.getMessage());
          System.out.println("replay fail set_schema failed for " + schema);
          return false;
        }
      }
    }
    PreparedStatement ps = c.prepareStatement(sql);
    try {
      for (String[] b : binds) {
        bindOne(ps, Integer.parseInt(b[0].trim()), b[1], b[2]);
      }
      boolean hasRs = ps.execute();
      if (hasRs) {
        ResultSet rs = ps.getResultSet();
        int cols = rs.getMetaData().getColumnCount();
        int rows = 0;
        while (rs.next() && rows < 20) {
          StringBuilder sb = new StringBuilder();
          for (int i = 1; i <= cols; i++) {
            if (i > 1) sb.append("|");
            sb.append(rs.getString(i));
          }
          System.out.println("replay row " + sb.toString());
          rows++;
        }
        System.out.println("replay rows-shown=" + rows);
        rs.close();
      } else {
        System.out.println("replay update-count=" + ps.getUpdateCount());
      }
      System.out.println("replay exec-ok");
      return true;
    } finally {
      ps.close();
    }
  }

  static Map<String, String[]> loadUserMaps(String path) throws IOException {
    Map<String, String[]> maps = new HashMap<String, String[]>();
    if (path == null || path.isEmpty() || "-".equals(path) || !Files.exists(Paths.get(path))) {
      return maps;
    }
    for (String ln : readFile(path).split("\n", -1)) {
      if (ln.isEmpty() || ln.startsWith("#")) continue;
      String[] p = splitPipeEscaped(ln, 3);
      if (p.length < 3) continue;
      String schema = p[0].trim().toUpperCase(Locale.ROOT);
      if (schema.isEmpty()) continue;
      maps.put(schema, new String[] { p[1].trim(), p[2] });
    }
    return maps;
  }

  /** Return [jdbcUser, jdbcPassword] for parsing_schema. */
  static String[] resolveExecCreds(String schema, String fallbackUser, String fallbackPass,
                                   Map<String, String[]> maps, boolean schemaViaAlter) {
    if (schemaViaAlter) {
      System.out.println("replay login-mode=alter-session user=" + fallbackUser);
      return new String[] { fallbackUser, fallbackPass };
    }
    if (schema != null && !schema.isEmpty() && !"NULL".equalsIgnoreCase(schema)) {
      String key = schema.toUpperCase(Locale.ROOT);
      if (maps.containsKey(key)) {
        String[] c = maps.get(key);
        System.out.println("replay map-hit schema=" + key + " user=" + c[0]);
        return c;
      }
      System.out.println("replay warn no [map." + key + "] in ini; try schema user + default password");
      return new String[] { schema, fallbackPass };
    }
    System.out.println("replay warn empty parsing_schema; fallback lookup user");
    return new String[] { fallbackUser, fallbackPass };
  }

  static Connection connectAs(String url, String user, String pass) throws SQLException {
    System.out.println("replay login-user=" + user);
    return DriverManager.getConnection(url, user, pass);
  }

  static void loadFromGv(String url, String lookupUser, String pass, String sqlId, String mode,
                         boolean force, Map<String, String[]> maps, boolean schemaViaAlter) throws Exception {
    String schema = null;
    int child = 0;
    int instId = 1;
    String sql = null;
    List<String[]> binds = new ArrayList<String[]>();
    Connection cLookup = DriverManager.getConnection(url, lookupUser, pass);
    System.out.println("replay lookup-user=" + lookupUser);
    PreparedStatement ps = null;
    ResultSet rs = null;
    try {
      try {
        ps = cLookup.prepareStatement(
          "SELECT parsing_schema_name, child_number, NVL(inst_id,1), sql_fulltext FROM (" +
          " SELECT parsing_schema_name, child_number, inst_id, sql_fulltext" +
          "   FROM gv$sql WHERE sql_id = ?" +
          "  ORDER BY last_active_time DESC NULLS LAST, executions DESC NULLS LAST, child_number" +
          ") WHERE ROWNUM = 1");
        ps.setString(1, sqlId);
        rs = ps.executeQuery();
        if (rs.next()) {
          schema = rs.getString(1);
          child = rs.getInt(2);
          instId = rs.getInt(3);
          sql = readClob(rs.getClob(4));
        }
      } catch (SQLException e) {
        System.out.println("replay warn gv$sql " + e.getMessage());
      } finally {
        if (rs != null) try { rs.close(); } catch (Exception e) {}
        if (ps != null) try { ps.close(); } catch (Exception e) {}
        rs = null; ps = null;
      }
      if (sql == null) {
        ps = cLookup.prepareStatement(
          "SELECT parsing_schema_name, child_number, sql_fulltext FROM (" +
          " SELECT parsing_schema_name, child_number, sql_fulltext" +
          "   FROM v$sql WHERE sql_id = ?" +
          "  ORDER BY last_active_time DESC NULLS LAST, executions DESC NULLS LAST, child_number" +
          ") WHERE ROWNUM = 1");
        ps.setString(1, sqlId);
        rs = ps.executeQuery();
        if (!rs.next()) {
          System.out.println("replay fail sql_id not found in gv$/v$sql: " + sqlId);
          System.exit(1);
        }
        schema = rs.getString(1);
        child = rs.getInt(2);
        instId = 1;
        sql = readClob(rs.getClob(3));
        rs.close();
        ps.close();
      }
      System.out.println("replay source=gv sql_id=" + sqlId + " child=" + child + " inst_id=" + instId);
      boolean gotBinds = false;
      try {
        ps = cLookup.prepareStatement(
          "SELECT position, datatype_string, value_string FROM gv$sql_bind_capture" +
          " WHERE sql_id = ? AND child_number = ? AND inst_id = ?" +
          " AND last_captured IS NOT NULL" +
          " ORDER BY position, name");
        ps.setString(1, sqlId);
        ps.setInt(2, child);
        ps.setInt(3, instId);
        rs = ps.executeQuery();
        while (rs.next()) {
          gotBinds = true;
          String val = rs.getString(3);
          binds.add(new String[] {
            String.valueOf(rs.getInt(1)),
            rs.getString(2) == null ? "" : rs.getString(2),
            val == null ? "" : val
          });
        }
        rs.close();
        ps.close();
      } catch (SQLException e) {
        System.out.println("replay warn gv$sql_bind_capture " + e.getMessage());
      }
      if (!gotBinds) {
        try {
          ps = cLookup.prepareStatement(
            "SELECT position, datatype_string, value_string FROM v$sql_bind_capture" +
            " WHERE sql_id = ? AND child_number = ? AND last_captured IS NOT NULL" +
            " ORDER BY position, name");
          ps.setString(1, sqlId);
          ps.setInt(2, child);
          rs = ps.executeQuery();
          while (rs.next()) {
            String val = rs.getString(3);
            binds.add(new String[] {
              String.valueOf(rs.getInt(1)),
              rs.getString(2) == null ? "" : rs.getString(2),
              val == null ? "" : val
            });
          }
          rs.close();
          ps.close();
        } catch (SQLException e) {
          System.out.println("replay warn bind_capture " + e.getMessage());
        }
      }
      String kind = classifySql(sql);
      String[] cred = resolveExecCreds(schema, lookupUser, pass, maps, schemaViaAlter);
      if ("dry".equalsIgnoreCase(mode) || (!force && !"query".equals(kind))) {
        System.out.println("replay login-user=" + cred[0] + " (planned)");
        boolean okDry = execSql(null, schema, sql, binds, mode, force);
        System.out.println("replay summary ok=" + (okDry ? 1 : 0) + " fail=" + (okDry ? 0 : 1));
        if (!okDry) System.exit(1);
        return;
      }
    } finally {
      try { cLookup.close(); } catch (Exception e) {}
    }
    String[] cred = resolveExecCreds(schema, lookupUser, pass, maps, schemaViaAlter);
    Connection cExec = connectAs(url, cred[0], cred[1]);
    boolean okExec;
    try {
      okExec = execSql(cExec, schema, sql, binds, mode, force, cred[0]);
    } finally {
      cExec.close();
    }
    System.out.println("replay summary ok=" + (okExec ? 1 : 0) + " fail=" + (okExec ? 0 : 1));
    if (!okExec) System.exit(1);
  }

  static void loadFromHtzOne(String url, String lookupUser, String pass, String sqlId, String mode,
                             boolean force, Map<String, String[]> maps, boolean schemaViaAlter) throws Exception {
    Connection cLookup = DriverManager.getConnection(url, lookupUser, pass);
    System.out.println("replay lookup-user=" + lookupUser);
    Object[] row = null;
    try {
      // Align with file export: single latest child only (max child_number).
      PreparedStatement ps = cLookup.prepareStatement(
        "SELECT child_number, parsing_schema, sql_fulltext, binds_json" +
        "  FROM SYS.HTZ_SQL_REPLAY_PKG WHERE sql_id = ?" +
        " ORDER BY child_number DESC");
      ps.setString(1, sqlId);
      ResultSet rs = ps.executeQuery();
      if (rs.next()) {
        row = new Object[] {
          Integer.valueOf(rs.getInt(1)),
          rs.getString(2),
          readClob(rs.getClob(3)),
          readClob(rs.getClob(4))
        };
      }
      rs.close();
      ps.close();
    } finally {
      try { cLookup.close(); } catch (Exception e) {}
    }
    if (row == null) {
      System.out.println("replay fail sql_id not found in HTZ_SQL_REPLAY_PKG: " + sqlId);
      System.exit(1);
    }
    int child = ((Integer) row[0]).intValue();
    String schema = (String) row[1];
    String sql = (String) row[2];
    String bj = (String) row[3];
    System.out.println("replay source=htz sql_id=" + sqlId + " child=" + child + " (latest_child_only)");
    List<String[]> binds = parseBindsJson(bj);
    String kind = classifySql(sql);
    String[] cred = resolveExecCreds(schema, lookupUser, pass, maps, schemaViaAlter);
    boolean ok;
    if ("dry".equalsIgnoreCase(mode) || (!force && !"query".equals(kind))) {
      System.out.println("replay login-user=" + cred[0] + " (planned)");
      ok = execSql(null, schema, sql, binds, mode, force);
    } else {
      Connection cExec = connectAs(url, cred[0], cred[1]);
      try {
        ok = execSql(cExec, schema, sql, binds, mode, force, cred[0]);
      } finally {
        cExec.close();
      }
    }
    System.out.println("replay summary ok=" + (ok ? 1 : 0) + " fail=" + (ok ? 0 : 1));
    if (!ok) System.exit(1);
  }

  static void loadFromHtzAll(String url, String lookupUser, String pass, String mode, boolean force,
                             Map<String, String[]> maps, boolean schemaViaAlter) throws Exception {
    Connection cLookup = DriverManager.getConnection(url, lookupUser, pass);
    System.out.println("replay lookup-user=" + lookupUser);
    // Keep latest child only per sql_id (match file export single-child semantics).
    LinkedHashMap<String, Object[]> latest = new LinkedHashMap<String, Object[]>();
    try {
      Statement st = cLookup.createStatement();
      ResultSet rs = st.executeQuery(
        "SELECT sql_id, child_number, parsing_schema, sql_fulltext, binds_json" +
        "  FROM SYS.HTZ_SQL_REPLAY_PKG ORDER BY sql_id, child_number");
      while (rs.next()) {
        String sid = rs.getString(1);
        Object[] row = new Object[] {
          sid,
          Integer.valueOf(rs.getInt(2)),
          rs.getString(3),
          readClob(rs.getClob(4)),
          readClob(rs.getClob(5))
        };
        latest.put(sid, row); // later higher child_number overwrites
      }
      rs.close();
      st.close();
    } finally {
      try { cLookup.close(); } catch (Exception e) {}
    }
    if (latest.isEmpty()) {
      System.out.println("replay fail HTZ_SQL_REPLAY_PKG is empty");
      System.exit(1);
    }
    int okN = 0;
    int failN = 0;
    for (Object[] row : latest.values()) {
      String sqlId = (String) row[0];
      int child = ((Integer) row[1]).intValue();
      String schema = (String) row[2];
      String sql = (String) row[3];
      String bj = (String) row[4];
      System.out.println("replay source=htz sql_id=" + sqlId + " child=" + child + " (latest_child_only)");
      List<String[]> binds = parseBindsJson(bj);
      String kind = classifySql(sql);
      String[] cred = resolveExecCreds(schema, lookupUser, pass, maps, schemaViaAlter);
      boolean ok;
      try {
        if ("dry".equalsIgnoreCase(mode) || (!force && !"query".equals(kind))) {
          System.out.println("replay login-user=" + cred[0] + " (planned)");
          ok = execSql(null, schema, sql, binds, mode, force);
        } else {
          Connection cExec = connectAs(url, cred[0], cred[1]);
          try {
            ok = execSql(cExec, schema, sql, binds, mode, force, cred[0]);
          } finally {
            cExec.close();
          }
        }
      } catch (Exception e) {
        System.out.println("replay fail " + e.getMessage());
        ok = false;
      }
      if (ok) okN++; else failN++;
    }
    System.out.println("replay summary ok=" + okN + " fail=" + failN);
    if (failN > 0) System.exit(1);
  }

  static boolean parseForce(String s) {
    return "1".equals(s) || "true".equalsIgnoreCase(s) || "yes".equalsIgnoreCase(s) || "force".equalsIgnoreCase(s);
  }

  public static void main(String[] args) throws Exception {
    if (args.length < 4) {
      System.err.println("usage:");
      System.err.println("  ... file schema sqlFile bindsFile dry|exec force mapsFile alterFlag");
      System.err.println("  ... gv sqlId dry|exec force mapsFile alterFlag");
      System.err.println("  ... htz sqlId dry|exec force mapsFile alterFlag");
      System.err.println("  ... htz_all dry|exec force mapsFile alterFlag");
      System.err.println("mapsFile lines: SCHEMA|jdbc_user|jdbc_password");
      System.err.println("alterFlag: 1/true => login lookup user + ALTER SESSION CURRENT_SCHEMA");
      System.exit(2);
    }
    String url = args[0];
    String lookupUser = args[1];
    String pass = args[2];
    String kind = args[3];
    Class.forName("com.yashandb.jdbc.Driver");
    if ("file".equals(kind)) {
      if (args.length < 10) { System.err.println("file mode needs schema sqlFile bindsFile mode force mapsFile [alterFlag]"); System.exit(2); }
      String schema = args[4];
      String sqlFile = args[5];
      String bindsFile = args[6];
      String mode = args[7];
      boolean force = parseForce(args[8]);
      Map<String, String[]> maps = loadUserMaps(args[9]);
      boolean schemaViaAlter = args.length >= 11 && parseForce(args[10]);
      String sql = readFile(sqlFile);
      List<String[]> binds = readBinds(bindsFile);
      System.out.println("replay source=file");
      String[] cred = resolveExecCreds(schema, lookupUser, pass, maps, schemaViaAlter);
      System.out.println("replay login-user=" + cred[0] + ("dry".equalsIgnoreCase(mode) ? " (planned)" : ""));
      boolean ok;
      if ("dry".equalsIgnoreCase(mode)) {
        ok = execSql(null, schema, sql, binds, mode, force);
      } else {
        Connection c = connectAs(url, cred[0], cred[1]);
        try { ok = execSql(c, schema, sql, binds, mode, force, cred[0]); }
        finally { c.close(); }
      }
      System.out.println("replay summary ok=" + (ok ? 1 : 0) + " fail=" + (ok ? 0 : 1));
      if (!ok) System.exit(1);
      return;
    }
    if ("gv".equals(kind)) {
      if (args.length < 8) { System.err.println("gv mode needs sqlId mode force mapsFile [alterFlag]"); System.exit(2); }
      try {
        boolean schemaViaAlter = args.length >= 9 && parseForce(args[8]);
        loadFromGv(url, lookupUser, pass, args[4], args[5], parseForce(args[6]), loadUserMaps(args[7]), schemaViaAlter);
      } catch (Exception e) {
        System.out.println("replay fail " + e.getMessage());
        System.exit(1);
      }
    } else if ("htz".equals(kind)) {
      if (args.length < 8) { System.err.println("htz mode needs sqlId mode force mapsFile [alterFlag]"); System.exit(2); }
      boolean schemaViaAlter = args.length >= 9 && parseForce(args[8]);
      loadFromHtzOne(url, lookupUser, pass, args[4], args[5], parseForce(args[6]), loadUserMaps(args[7]), schemaViaAlter);
    } else if ("htz_all".equals(kind)) {
      if (args.length < 7) { System.err.println("htz_all mode needs mode force mapsFile [alterFlag]"); System.exit(2); }
      boolean schemaViaAlter = args.length >= 8 && parseForce(args[7]);
      loadFromHtzAll(url, lookupUser, pass, args[4], parseForce(args[5]), loadUserMaps(args[6]), schemaViaAlter);
    } else {
      System.err.println("unknown kind: " + kind);
      System.exit(2);
    }
  }
}

"""


def parse_sql_id_list(raw):
    # type: (object) -> list
    """Split --sql-id by comma; empty/None -> []."""
    if raw is None:
        return []
    s = str(raw).strip()
    if not s:
        return []
    out = []
    for part in s.split(","):
        sid = part.strip()
        if sid:
            out.append(sid)
    return out


def build_replay_export_sql(sql_id):
    # type: (str) -> str
    """Upsert HTZ_SQL_REPLAY_PKG and emit meta/binds/orig markers for one sql_id."""
    sid = sql_id.replace("'", "''")
    return (
        "SET SERVEROUTPUT ON\n"
        "DECLARE\n"
        "  v_sql_id VARCHAR2(13) := '{sid}';\n"
        "  v_child NUMBER;\n"
        "  v_schema VARCHAR2(128);\n"
        "  v_inst NUMBER;\n"
        "  v_hash NUMBER;\n"
        "  v_len NUMBER;\n"
        "  v_txt CLOB;\n"
        "  v_json CLOB;\n"
        "  v_n NUMBER;\n"
        "  v_first BOOLEAN := TRUE;\n"
        "  v_val VARCHAR2(4000);\n"
        "  v_name VARCHAR2(128);\n"
        "  v_off NUMBER;\n"
        "  v_buf VARCHAR2(4000);\n"
        "  v_chunk CONSTANT PLS_INTEGER := {chunk};\n"
        "BEGIN\n"
        "  SELECT COUNT(*) INTO v_n FROM dba_tables\n"
        "   WHERE owner='SYS' AND table_name='HTZ_SQL_REPLAY_PKG';\n"
        "  IF v_n = 0 THEN\n"
        "    EXECUTE IMMEDIATE '\n"
        "      CREATE TABLE SYS.HTZ_SQL_REPLAY_PKG (\n"
        "        SQL_ID VARCHAR2(13) NOT NULL,\n"
        "        CHILD_NUMBER NUMBER NOT NULL,\n"
        "        INST_ID NUMBER,\n"
        "        HASH_VALUE NUMBER,\n"
        "        PARSING_SCHEMA VARCHAR2(128),\n"
        "        SQL_FULLTEXT CLOB,\n"
        "        BINDS_JSON CLOB,\n"
        "        SQL_LEN NUMBER,\n"
        "        COLLECT_TIME DATE,\n"
        "        CONSTRAINT PK_HTZ_SQL_REPLAY_PKG PRIMARY KEY (SQL_ID, CHILD_NUMBER)\n"
        "      )';\n"
        "    DBMS_OUTPUT.PUT_LINE('TABLE HTZ_SQL_REPLAY_PKG created');\n"
        "  END IF;\n"
        "\n"
        "  BEGIN\n"
        "    SELECT child_number, parsing_schema_name, inst_id, hash_value, sql_fulltext,\n"
        "           DBMS_LOB.GETLENGTH(sql_fulltext)\n"
        "      INTO v_child, v_schema, v_inst, v_hash, v_txt, v_len\n"
        "      FROM (\n"
        "            SELECT child_number, parsing_schema_name,\n"
        "                   NVL(inst_id, 1) AS inst_id, hash_value, sql_fulltext\n"
        "              FROM gv$sql\n"
        "             WHERE sql_id = v_sql_id\n"
        "             ORDER BY last_active_time DESC NULLS LAST,\n"
        "                      executions DESC NULLS LAST,\n"
        "                      child_number\n"
        "           )\n"
        "     WHERE ROWNUM = 1;\n"
        "  EXCEPTION\n"
        "    WHEN NO_DATA_FOUND THEN\n"
        "      BEGIN\n"
        "        SELECT child_number, parsing_schema_name, 1, hash_value, sql_fulltext,\n"
        "               DBMS_LOB.GETLENGTH(sql_fulltext)\n"
        "          INTO v_child, v_schema, v_inst, v_hash, v_txt, v_len\n"
        "          FROM (\n"
        "                SELECT child_number, parsing_schema_name, hash_value, sql_fulltext\n"
        "                  FROM v$sql\n"
        "                 WHERE sql_id = v_sql_id\n"
        "                 ORDER BY last_active_time DESC NULLS LAST,\n"
        "                          executions DESC NULLS LAST,\n"
        "                          child_number\n"
        "               )\n"
        "         WHERE ROWNUM = 1;\n"
        "      EXCEPTION\n"
        "        WHEN NO_DATA_FOUND THEN\n"
        "          DBMS_OUTPUT.PUT_LINE('REPLAY_EXPORT_NO_SQL');\n"
        "          RETURN;\n"
        "      END;\n"
        "  END;\n"
        "\n"
        "  DBMS_LOB.CREATETEMPORARY(v_json, TRUE);\n"
        "  DBMS_LOB.WRITEAPPEND(v_json, 1, '[');\n"
        "  v_n := 0;\n"
        "  BEGIN\n"
        "    FOR r IN (\n"
        "      SELECT position, name, datatype_string, value_string, was_captured\n"
        "        FROM gv$sql_bind_capture\n"
        "       WHERE sql_id = v_sql_id AND child_number = v_child\n"
        "         AND NVL(inst_id,1) = NVL(v_inst,1)\n"
        "         AND last_captured IS NOT NULL\n"
        "       ORDER BY position, name\n"
        "    ) LOOP\n"
        "      v_n := v_n + 1;\n"
        "      IF v_n > 1 THEN\n"
        "        DBMS_LOB.WRITEAPPEND(v_json, 1, ',');\n"
        "      END IF;\n"
        "      v_name := REPLACE(NVL(r.name, ''), '\"', '\\\"');\n"
        "      v_val := REPLACE(REPLACE(NVL(r.value_string, ''), '\\\\', '\\\\\\\\'), '\"', '\\\"');\n"
        "      v_val := REPLACE(REPLACE(REPLACE(v_val, CHR(10), '\\\\n'), CHR(13), ''), CHR(9), '\\\\t');\n"
        "      v_buf := '{{\"position\":' || TO_CHAR(r.position)\n"
        "            || ',\"name\":\"' || v_name || '\"'\n"
        "            || ',\"datatype\":\"' || REPLACE(NVL(r.datatype_string,''), '\"', '') || '\"'\n"
        "            || ',\"was_captured\":\"' || NVL(r.was_captured,'') || '\"'\n"
        "            || ',\"value\":\"' || v_val || '\"}}';\n"
        "      DBMS_LOB.WRITEAPPEND(v_json, LENGTH(v_buf), v_buf);\n"
        "    END LOOP;\n"
        "  EXCEPTION WHEN OTHERS THEN\n"
        "    v_n := 0;\n"
        "  END;\n"
        "  IF v_n = 0 THEN\n"
        "    FOR r IN (\n"
        "      SELECT position, name, datatype_string, value_string, was_captured\n"
        "        FROM v$sql_bind_capture\n"
        "       WHERE sql_id = v_sql_id AND child_number = v_child\n"
        "         AND last_captured IS NOT NULL\n"
        "       ORDER BY position, name\n"
        "    ) LOOP\n"
        "      v_n := v_n + 1;\n"
        "      IF v_n > 1 THEN\n"
        "        DBMS_LOB.WRITEAPPEND(v_json, 1, ',');\n"
        "      END IF;\n"
        "      v_name := REPLACE(NVL(r.name, ''), '\"', '\\\"');\n"
        "      v_val := REPLACE(REPLACE(NVL(r.value_string, ''), '\\\\', '\\\\\\\\'), '\"', '\\\"');\n"
        "      v_val := REPLACE(REPLACE(REPLACE(v_val, CHR(10), '\\\\n'), CHR(13), ''), CHR(9), '\\\\t');\n"
        "      v_buf := '{{\"position\":' || TO_CHAR(r.position)\n"
        "            || ',\"name\":\"' || v_name || '\"'\n"
        "            || ',\"datatype\":\"' || REPLACE(NVL(r.datatype_string,''), '\"', '') || '\"'\n"
        "            || ',\"was_captured\":\"' || NVL(r.was_captured,'') || '\"'\n"
        "            || ',\"value\":\"' || v_val || '\"}}';\n"
        "      DBMS_LOB.WRITEAPPEND(v_json, LENGTH(v_buf), v_buf);\n"
        "    END LOOP;\n"
        "  END IF;\n"
        "  DBMS_LOB.WRITEAPPEND(v_json, 1, ']');\n"
        "\n"
        "  EXECUTE IMMEDIATE\n"
        "    'DELETE FROM SYS.HTZ_SQL_REPLAY_PKG WHERE sql_id = :1 AND child_number = :2'\n"
        "    USING v_sql_id, v_child;\n"
        "  EXECUTE IMMEDIATE\n"
        "    'INSERT INTO SYS.HTZ_SQL_REPLAY_PKG\n"
        "       (sql_id, child_number, inst_id, hash_value, parsing_schema,\n"
        "        sql_fulltext, binds_json, sql_len, collect_time)\n"
        "     VALUES (:1,:2,:3,:4,:5,:6,:7,:8,SYSDATE)'\n"
        "    USING v_sql_id, v_child, v_inst, v_hash, v_schema, v_txt, v_json, v_len;\n"
        "\n"
        "  DBMS_OUTPUT.PUT_LINE('{m0}');\n"
        "  DBMS_OUTPUT.PUT_LINE('sql_id=' || v_sql_id);\n"
        "  DBMS_OUTPUT.PUT_LINE('child_number=' || TO_CHAR(v_child));\n"
        "  DBMS_OUTPUT.PUT_LINE('inst_id=' || TO_CHAR(NVL(v_inst,1)));\n"
        "  DBMS_OUTPUT.PUT_LINE('hash_value=' || TO_CHAR(NVL(v_hash,0)));\n"
        "  DBMS_OUTPUT.PUT_LINE('parsing_schema=' || NVL(v_schema,''));\n"
        "  DBMS_OUTPUT.PUT_LINE('sql_len=' || TO_CHAR(NVL(v_len,0)));\n"
        "  DBMS_OUTPUT.PUT_LINE('{m1}');\n"
        "\n"
        "  DBMS_OUTPUT.PUT_LINE('{b0}');\n"
        "  v_n := 0;\n"
        "  BEGIN\n"
        "    FOR r IN (\n"
        "      SELECT position, name, datatype_string, value_string, was_captured\n"
        "        FROM gv$sql_bind_capture\n"
        "       WHERE sql_id = v_sql_id AND child_number = v_child\n"
        "         AND NVL(inst_id,1) = NVL(v_inst,1)\n"
        "         AND last_captured IS NOT NULL\n"
        "       ORDER BY position, name\n"
        "    ) LOOP\n"
        "      v_n := v_n + 1;\n"
        "      v_name := REPLACE(REPLACE(NVL(r.name,''), CHR(92), CHR(92)||CHR(92)), '|', CHR(92)||'|');\n"
        "      v_val := REPLACE(REPLACE(NVL(r.value_string,''), CHR(10), ' '), CHR(92), CHR(92)||CHR(92));\n"
        "      v_val := REPLACE(REPLACE(v_val, CHR(9), ' '), '|', CHR(92)||'|');\n"
        "      DBMS_OUTPUT.PUT_LINE(\n"
        "        TO_CHAR(r.position) || '|' || v_name || '|' ||\n"
        "        REPLACE(REPLACE(NVL(r.datatype_string,''), CHR(92), CHR(92)||CHR(92)), '|', CHR(92)||'|')\n"
        "        || '|' || NVL(r.was_captured,'') || '|' || v_val);\n"
        "    END LOOP;\n"
        "  EXCEPTION WHEN OTHERS THEN\n"
        "    v_n := 0;\n"
        "  END;\n"
        "  IF v_n = 0 THEN\n"
        "    FOR r IN (\n"
        "      SELECT position, name, datatype_string, value_string, was_captured\n"
        "        FROM v$sql_bind_capture\n"
        "       WHERE sql_id = v_sql_id AND child_number = v_child\n"
        "         AND last_captured IS NOT NULL\n"
        "       ORDER BY position, name\n"
        "    ) LOOP\n"
        "      v_name := REPLACE(REPLACE(NVL(r.name,''), CHR(92), CHR(92)||CHR(92)), '|', CHR(92)||'|');\n"
        "      v_val := REPLACE(REPLACE(NVL(r.value_string,''), CHR(10), ' '), CHR(92), CHR(92)||CHR(92));\n"
        "      v_val := REPLACE(REPLACE(v_val, CHR(9), ' '), '|', CHR(92)||'|');\n"
        "      DBMS_OUTPUT.PUT_LINE(\n"
        "        TO_CHAR(r.position) || '|' || v_name || '|' ||\n"
        "        REPLACE(REPLACE(NVL(r.datatype_string,''), CHR(92), CHR(92)||CHR(92)), '|', CHR(92)||'|')\n"
        "        || '|' || NVL(r.was_captured,'') || '|' || v_val);\n"
        "    END LOOP;\n"
        "  END IF;\n"
        "  DBMS_OUTPUT.PUT_LINE('{b1}');\n"
        "\n"
        "  DBMS_OUTPUT.PUT_LINE('{o0}');\n"
        "  v_off := 1;\n"
        "  WHILE v_off <= NVL(v_len, 0) LOOP\n"
        "    v_buf := DBMS_LOB.SUBSTR(v_txt, LEAST(v_chunk, v_len - v_off + 1), v_off);\n"
        "    DBMS_OUTPUT.PUT_LINE(v_buf);\n"
        "    v_off := v_off + v_chunk;\n"
        "  END LOOP;\n"
        "  DBMS_OUTPUT.PUT_LINE('{o1}');\n"
        "  DBMS_OUTPUT.PUT_LINE('REPLAY_EXPORT_OK');\n"
        "END;\n"
        "/\n"
        "EXIT;\n"
    ).format(
        sid=sid,
        chunk=CLOB_CHUNK,
        m0=MARK_REPLAY_META_START,
        m1=MARK_REPLAY_META_END,
        b0=MARK_REPLAY_BIND_START,
        b1=MARK_REPLAY_BIND_END,
        o0=MARK_REPLAY_ORIG_START,
        o1=MARK_REPLAY_ORIG_END,
    )


def _parse_marked_block(out, start_mark, end_mark):
    # type: (str, str, str) -> list
    lines = []
    in_blk = False
    for ln in out.splitlines():
        s = ln.rstrip("\n")
        if s.strip() == start_mark:
            in_blk = True
            continue
        if s.strip() == end_mark:
            break
        if in_blk:
            lines.append(s)
    return lines


def export_replay_package(sql_id, outdir, connect_str, yasql_path, kind="NEW"):
    # type: (str, str, str, str, str) -> bool
    """Write outdir/replay/<sql_id>__cN/ and upsert SYS.HTZ_SQL_REPLAY_PKG.
    kind: NEW (first collect) or REFRESH (bind refresh re-export).
    """
    path = write_temp_sql(build_replay_export_sql(sql_id))
    try:
        rc, out = yasql_run(path, connect_str, yasql_path, timeout=YASQL_TIMEOUT)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    if "REPLAY_EXPORT_NO_SQL" in out:
        eprint("[WARN] replay export: sql_id not in v$/gv$sql: {0}".format(sql_id))
        return False
    if "REPLAY_EXPORT_OK" not in out:
        eprint("[WARN] replay export failed for {0} rc={1}".format(sql_id, rc))
        eprint(out[-2500:] if out else "(no output)")
        return False

    meta_lines = _parse_marked_block(out, MARK_REPLAY_META_START, MARK_REPLAY_META_END)
    bind_lines = _parse_marked_block(out, MARK_REPLAY_BIND_START, MARK_REPLAY_BIND_END)
    orig_lines = _parse_marked_block(out, MARK_REPLAY_ORIG_START, MARK_REPLAY_ORIG_END)
    meta = {}
    for ln in meta_lines:
        if "=" in ln:
            k, v = ln.split("=", 1)
            meta[k.strip()] = v.strip()
    child = meta.get("child_number", "0")
    pkg_dir = os.path.join(
        outdir, REPLAY_DIRNAME, "{0}__c{1}".format(sql_id, child)
    )
    if not os.path.isdir(pkg_dir):
        os.makedirs(pkg_dir)

    binds = []
    binds_txt = []
    for ln in bind_lines:
        parts = ln.split("|", 4)
        # Prefer escaped split when backslash-pipe present
        if "\\|" in ln or "\\\\" in ln:
            # manual split respecting escapes (same as Java splitPipeEscaped, 5 fields)
            fields = []
            cur = []
            esc = False
            for ch in ln:
                if esc:
                    cur.append(ch)
                    esc = False
                    continue
                if ch == "\\":
                    esc = True
                    continue
                if ch == "|" and len(fields) < 4:
                    fields.append("".join(cur))
                    cur = []
                    continue
                cur.append(ch)
            fields.append("".join(cur))
            parts = fields
        if len(parts) < 1 or not parts[0].strip().isdigit():
            continue
        pos = int(parts[0].strip())
        name = unescape_pipe_field(parts[1] if len(parts) > 1 else "")
        dtype = unescape_pipe_field(parts[2] if len(parts) > 2 else "")
        was = unescape_pipe_field(parts[3] if len(parts) > 3 else "")
        val = unescape_pipe_field(parts[4] if len(parts) > 4 else "")
        binds.append(
            {
                "position": pos,
                "name": name,
                "datatype": dtype,
                "was_captured": was,
                "value": val,
            }
        )
        binds_txt.append(
            "{0}|{1}|{2}".format(
                pos, escape_pipe_field(dtype), escape_pipe_field(val)
            )
        )

    try:
        with open(os.path.join(pkg_dir, "meta.txt"), "w") as fh:
            for k in (
                "sql_id",
                "child_number",
                "inst_id",
                "hash_value",
                "parsing_schema",
                "sql_len",
            ):
                fh.write("{0}={1}\n".format(k, meta.get(k, "")))
        with open(os.path.join(pkg_dir, "binds.json"), "w") as fh:
            json.dump(binds, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        with open(os.path.join(pkg_dir, "binds.txt"), "w") as fh:
            fh.write("# position|datatype|value\n")
            for ln in binds_txt:
                fh.write(ln + "\n")
        # ORIG: join chunk lines without adding extra newlines between chunks
        # (DBMS_OUTPUT.PUT_LINE adds newline per chunk; strip one trailing NL per line)
        orig = "".join(orig_lines)
        with open(os.path.join(pkg_dir, "orig.sql"), "w") as fh:
            fh.write(orig)
            if orig and not orig.endswith("\n"):
                fh.write("\n")
    except OSError as exc:
        eprint("[ERROR] write replay package {0}: {1}".format(pkg_dir, exc))
        return False

    # Canonicalize HTZ binds_json with Python json (TAB/control-safe).
    try:
        _update_htz_binds_json(
            sql_id, child, binds, connect_str, yasql_path
        )
    except Exception as exc:
        eprint(
            "[WARN] HTZ binds_json canonicalize failed for {0}: {1}".format(
                sql_id, exc
            )
        )

    kind_u = (kind or "NEW").upper()
    if kind_u not in ("NEW", "REFRESH"):
        kind_u = "NEW"
    # 行为标签: new / refresh (小写, 无 collect 前缀)
    kind_tag = "refresh" if kind_u == "REFRESH" else "new"
    log_info(
        "{0} export sql_id={1} child={2} len={3} binds={4} -> {5}".format(
            kind_tag,
            sql_id,
            child,
            meta.get("sql_len", ""),
            len(binds),
            pkg_dir,
        )
    )
    log_dbg(
        "export_replay_package done kind={0} sql_id={1} child={2} pkg={3}".format(
            kind_u, sql_id, child, pkg_dir
        )
    )
    empty_vals = [b for b in binds if b.get("value", "") == ""]
    if empty_vals:
        eprint(
            "[WARN] {0} bind(s) have empty value_string; sql_id={1} edit binds.txt before execute".format(
                len(empty_vals), sql_id
            )
        )
    return True


JDBC_CONFIG_TEMPLATE = """# sql_collect.py JDBC replay config
# Default path: ./jdbc_replay.ini  (override: --jdbc-config)
# Generate: python3 sql_collect.py replay --init-config

[jdbc]
# Path to YashanDB JDBC driver jar
jdbc_jar = /path/to/yashandb-jdbc-1.9.18.jar
# Full JDBC URL (required; no host/port fallback)
jdbc_url = jdbc:yasdb://127.0.0.1:1688/yasdb
# Lookup account for gv$/v$sql and SYS.HTZ_* reads
user = htz
# Fallback password when [map.SCHEMA] is missing
password = change_me
# true: always JDBC-login as [jdbc] user, then ALTER SESSION SET CURRENT_SCHEMA
# false (default): login via [map.SCHEMA] (or schema name + fallback password)
# schema_via_alter = false

# Optional: per parsing_schema JDBC login for execute (ignored when schema_via_alter=true)
# [map.HTZ]
# user = htz
# password = change_me
#
# [map.APP1]
# user = app1
# password = change_me
"""


def resolve_jdbc_config_path(path=None):
    # type: (object) -> str
    """Absolute path of JDBC INI (default ./jdbc_replay.ini or env)."""
    raw = path if path not in (None, "") else DEFAULT_JDBC_CONFIG
    return os.path.abspath(os.path.expanduser(str(raw)))


def write_jdbc_config_template(path=None, overwrite=False):
    # type: (object, bool) -> str
    """Write JDBC INI template; return absolute path."""
    dest = resolve_jdbc_config_path(path)
    if os.path.isfile(dest) and not overwrite:
        raise IOError(
            "jdbc config already exists: {0} (pass --overwrite to replace)".format(dest)
        )
    parent = os.path.dirname(dest)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open(dest, "w") as fh:
        fh.write(JDBC_CONFIG_TEMPLATE)
        if not JDBC_CONFIG_TEMPLATE.endswith("\n"):
            fh.write("\n")
    return dest


def load_jdbc_ini(path):
    # type: (object) -> dict
    """Load JDBC INI: [jdbc] + optional [map.SCHEMA] user/password maps."""
    path = resolve_jdbc_config_path(path)
    if not os.path.isfile(path):
        raise IOError(
            "jdbc config not found: {0}\n"
            "  generate template: {1} replay --init-config\n"
            "  or pass --jdbc-config /path/to.ini".format(
                path, PROG
            )
        )
    raw = ""
    with open(path, "r") as fh:
        raw = fh.read()
    if not raw.strip():
        raise ValueError("jdbc config empty: {0}".format(path))
    text = raw
    if "[" not in text.split("\n", 1)[0] and not re.search(
        r"(?m)^\s*\[[^\]]+\]\s*$", text
    ):
        text = "[jdbc]\n" + text
    # Disable %() interpolation so passwords may contain '%'
    try:
        cp = configparser.ConfigParser(interpolation=None)  # type: ignore
    except TypeError:
        # Py2 / very old configparser
        cp = configparser.RawConfigParser()  # type: ignore
    try:
        # Py3
        cp.read_string(text)  # type: ignore
    except AttributeError:
        import io

        cp.readfp(io.StringIO(text))  # type: ignore
    section = "jdbc"
    if not cp.has_section(section):
        secs = [s for s in cp.sections() if not s.lower().startswith("map.")]
        if not secs:
            raise ValueError("jdbc config has no [jdbc] section: {0}".format(path))
        section = secs[0]
    cfg = {}
    for k, v in cp.items(section):
        cfg[k.strip().lower()] = v.strip()
    jar = cfg.get("jdbc_jar") or cfg.get("jar")
    url = cfg.get("jdbc_url") or cfg.get("url")
    user = cfg.get("user") or cfg.get("username")
    password = cfg.get("password") or cfg.get("passwd") or ""
    if not url:
        raise ValueError(
            "jdbc config needs jdbc_url "
            "(e.g. jdbc_url = jdbc:yasdb://10.10.10.170:1688/yasdb)"
        )
    if not jar:
        raise ValueError("jdbc config needs jdbc_jar")
    if not user:
        raise ValueError("jdbc config needs user")
    if not os.path.isfile(jar):
        raise IOError("jdbc_jar not found: {0}".format(jar))
    maps = {}
    for sec in cp.sections():
        if not sec.lower().startswith("map."):
            continue
        schema = sec.split(".", 1)[1].strip().upper()
        if not schema:
            continue
        opt = {}
        for k, v in cp.items(sec):
            opt[k.strip().lower()] = v.strip()
        map_user = opt.get("user") or opt.get("username") or schema
        map_pass = opt.get("password") or opt.get("passwd")
        if map_pass is None:
            map_pass = password
        maps[schema] = (map_user, map_pass)
    via = _ini_truthy(cfg.get("schema_via_alter") or cfg.get("login_mode_alter"))
    return {
        "jdbc_jar": jar,
        "jdbc_url": url,
        "user": user,
        "password": password,
        "maps": maps,
        "schema_via_alter": via,
        "config_path": path,
    }


def _ini_truthy(value):
    # type: (object) -> bool
    if value is None:
        return False
    s = str(value).strip().lower()
    return s in (
        "1",
        "true",
        "yes",
        "on",
        "alter",
        "alter-session",
        "alter_session",
    )


def escape_pipe_field(value):
    # type: (object) -> str
    """Escape backslash and pipe for SCHEMA|user|password / binds.txt fields."""
    s = "" if value is None else str(value)
    return s.replace("\\", "\\\\").replace("|", "\\|")


def unescape_pipe_field(value):
    # type: (object) -> str
    """Inverse of escape_pipe_field (Python-side parse helper)."""
    s = "" if value is None else str(value)
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            out.append(s[i + 1])
            i += 2
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def write_user_maps_file(path, maps):
    # type: (str, dict) -> None
    """Write SCHEMA|jdbc_user|jdbc_password lines for SqlReplayJdbc (| escaped)."""
    with open(path, "w") as fh:
        fh.write("# schema|jdbc_user|jdbc_password (\\ and | escaped)\n")
        for schema in sorted(maps.keys()):
            u, p = maps[schema]
            fh.write(
                "{0}|{1}|{2}\n".format(
                    escape_pipe_field(schema),
                    escape_pipe_field(u),
                    escape_pipe_field(p),
                )
            )



def _update_htz_binds_json(sql_id, child, binds, connect_str, yasql_path):
    # type: (str, object, list, str, str) -> None
    """Rewrite SYS.HTZ_SQL_REPLAY_PKG.binds_json with Python-canonical JSON."""
    payload = json.dumps(binds, ensure_ascii=True, separators=(",", ":"))
    step = 800
    body = [
        "SET SERVEROUTPUT ON",
        "DECLARE",
        "  v_json CLOB;",
        "  v_sid VARCHAR2(13) := '{0}';".format(str(sql_id).replace("'", "''")),
        "  v_child NUMBER := {0};".format(int(child)),
        "BEGIN",
        "  DBMS_LOB.CREATETEMPORARY(v_json, TRUE);",
    ]
    for i in range(0, len(payload), step):
        piece_raw = payload[i : i + step]
        piece_sql = piece_raw.replace("'", "''")
        body.append(
            "  DBMS_LOB.WRITEAPPEND(v_json, {0}, '{1}');".format(
                len(piece_raw), piece_sql
            )
        )
    body.extend(
        [
            "  UPDATE SYS.HTZ_SQL_REPLAY_PKG",
            "     SET binds_json = v_json",
            "   WHERE sql_id = v_sid AND child_number = v_child;",
            "  COMMIT;",
            "  DBMS_OUTPUT.PUT_LINE('HTZ_BINDS_JSON_OK');",
            "END;",
            "/",
            "EXIT;",
        ]
    )
    path = write_temp_sql("\n".join(body) + "\n")
    try:
        rc, out = yasql_run(path, connect_str, yasql_path, timeout=120)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    if "HTZ_BINDS_JSON_OK" not in (out or ""):
        raise RuntimeError("update HTZ binds_json failed rc={0}".format(rc))


def list_replay_packages(outdir, sql_ids=None):
    # type: (str, object) -> list
    """List replay package dirs (latest child only per sql_id). sql_ids: None=all."""
    root = os.path.join(outdir, REPLAY_DIRNAME)
    if not os.path.isdir(root):
        return []
    id_set = set(sql_ids) if sql_ids else None
    # name -> (sql_id, child, path)
    best = {}
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        if not os.path.isdir(d):
            continue
        orig = os.path.join(d, "orig.sql")
        meta_path = os.path.join(d, "meta.txt")
        if not os.path.isfile(orig) or not os.path.isfile(meta_path):
            continue
        meta = read_meta_file(meta_path)
        sid = (meta.get("sql_id") or "").strip()
        if not sid:
            # fallback parse from dirname sqlid__cN
            if "__c" in name:
                sid = name.rsplit("__c", 1)[0]
            else:
                sid = name
        try:
            child = int(str(meta.get("child_number", "0")).strip() or "0")
        except ValueError:
            child = 0
            if "__c" in name:
                try:
                    child = int(name.rsplit("__c", 1)[1])
                except ValueError:
                    child = 0
        if id_set is not None:
            matched = False
            for want in id_set:
                if sid == want or name.startswith(want + "__c") or name == want:
                    matched = True
                    break
            if not matched:
                continue
        prev = best.get(sid)
        if prev is None or child >= prev[0]:
            best[sid] = (child, d)
    pkgs = [best[k][1] for k in sorted(best.keys())]
    return pkgs


def read_meta_file(path):
    # type: (str) -> dict
    meta = {}
    with open(path, "r") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            meta[k.strip()] = v.strip()
    return meta


_JAVAC_LOCK = threading.Lock()
_REPLAY_PRINT_LOCK = threading.Lock()


def ensure_replay_java_class(work_dir, jdbc_jar):
    # type: (str, str) -> str
    """Write/compile SqlReplayJdbc.java; return directory containing .class."""
    with _JAVAC_LOCK:
        src = os.path.join(work_dir, "SqlReplayJdbc.java")
        cls = os.path.join(work_dir, "SqlReplayJdbc.class")
        log_step("javac", src)
        with open(src, "w") as fh:
            fh.write(REPLAY_JDBC_JAVA)
        if os.path.isfile(cls) and os.path.getmtime(cls) >= os.path.getmtime(src):
            log_dbg("javac skip (up-to-date) class={0}".format(cls))
            return work_dir
        javac = "javac"
        cmd = [javac, "-cp", jdbc_jar, src]
        t0 = time.time()
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        _out, err = proc.communicate()
        out = (_out or b"").decode("utf-8", errors="replace")
        err_s = (err or b"").decode("utf-8", errors="replace")
        lg = _LOG
        if lg is not None:
            lg.command_result(
                "javac", " ".join(cmd), proc.returncode, out + err_s, time.time() - t0
            )
        if proc.returncode != 0:
            raise RuntimeError("javac failed: {0}".format(err_s))
        return work_dir


def _run_replay_java(jdbc_cfg, java_args, dry_run=False, work_dir=None, label=None):
    # type: (dict, list, bool, object, object) -> bool
    """Run SqlReplayJdbc; work_dir if set reuses compiled class (caller cleans up)."""
    owned = work_dir is None
    if owned:
        work_dir = tempfile.mkdtemp(prefix="sql_replay_jdbc_")
    try:
        ensure_replay_java_class(work_dir, jdbc_cfg["jdbc_jar"])
        maps_file = jdbc_cfg.get("maps_file")
        if not maps_file:
            maps_file = os.path.join(work_dir, "user_maps.txt")
            write_user_maps_file(maps_file, jdbc_cfg.get("maps") or {})
            jdbc_cfg["maps_file"] = maps_file
        cp = work_dir + os.pathsep + jdbc_cfg["jdbc_jar"]
        cmd = [
            "java",
            "-Djava.net.preferIPv4Stack=true",
            "-Djava.net.useSystemProxies=false",
            "-cp",
            cp,
            "SqlReplayJdbc",
            jdbc_cfg["jdbc_url"],
            jdbc_cfg["user"],
            jdbc_cfg["password"],
        ] + list(java_args) + [
            maps_file,
            _alter_flag(bool(jdbc_cfg.get("schema_via_alter"))),
        ]
        cmd_disp = " ".join(cmd)
        log_step("jdbc_replay", label or ",".join(str(x) for x in java_args[:3]))
        log_dbg("jdbc cmd={0}".format(cmd_disp))
        t0 = time.time()
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        timed_out = False
        rc_override = None
        try:
            stdout, stderr = proc.communicate(timeout=JDBC_TIMEOUT)
        except TypeError:
            stdout, stderr = proc.communicate()
        except Exception as exc:
            if type(exc).__name__ != "TimeoutExpired":
                raise
            timed_out = True
            try:
                proc.kill()
            except OSError:
                pass
            stdout, stderr = proc.communicate()
            extra = "\n[ERROR] jdbc timeout after {0}s\n".format(JDBC_TIMEOUT)
            stdout = (stdout or b"") + extra.encode("utf-8")
            rc_override = 124
        out = stdout.decode("utf-8", errors="replace") if stdout else ""
        err = stderr.decode("utf-8", errors="replace") if stderr else ""
        elapsed = time.time() - t0
        jdbc_rc = rc_override if rc_override is not None else proc.returncode
        if timed_out:
            eprint(
                "[ERROR] jdbc timeout after {0}s label={1}".format(JDBC_TIMEOUT, label)
            )
        prefix = "[jdbc]"
        if label:
            prefix = "[jdbc:{0}]".format(label)
        lg = _LOG
        if lg is not None:
            lg.command_result(
                "jdbc:" + (label or "replay"),
                cmd_disp,
                jdbc_rc,
                out + "\n" + err,
                elapsed,
            )
        with _REPLAY_PRINT_LOCK:
            # Terminal: summary + high-signal markers; full JDBC dump in debug
            markers = []
            for ln in out.splitlines():
                if ln.startswith(
                    (
                        "replay map-hit",
                        "replay login-mode=",
                        "replay warn",
                        "replay login-user",
                        "replay exec-ok",
                        "replay dry-run-ok",
                        "replay blocked",
                        "replay fail",
                        "replay source=",
                        "replay sql-chars=",
                        "replay sql-kind=",
                        "replay schema-set=",
                        "replay schema-skip",
                        "replay summary ",
                    )
                ):
                    markers.append(ln)
            status = "ok"
            if "replay fail" in out:
                status = "fail"
            elif "replay blocked" in out:
                status = "blocked"
            elif jdbc_rc != 0:
                status = "error"
            log_info(
                "jdbc {0} rc={1} status={2} {3}s".format(
                    label or "-",
                    jdbc_rc,
                    status,
                    "{0:.2f}".format(elapsed),
                )
            )
            for ln in markers:
                log_info(ln)
            if err.strip():
                for ln in err.splitlines()[-30:]:
                    if "maxStringLen" in ln or "JDKLoggerAdapter" in ln:
                        continue
                    eprint("jdbc-err {0}".format(ln))
        ok_token = "replay dry-run-ok" if dry_run else "replay exec-ok"
        blocked = "replay blocked" in out
        failed = "replay fail" in out
        ok = jdbc_rc == 0 and ok_token in out and not failed
        if dry_run and blocked and ok_token in out and not failed:
            ok = True
        for ln in out.splitlines():
            if ln.startswith("replay summary "):
                mfail = re.search(r"fail=(\d+)", ln)
                if mfail and int(mfail.group(1)) > 0:
                    ok = False
                break
        if not ok:
            with _REPLAY_PRINT_LOCK:
                eprint(
                    "[ERROR] jdbc replay failed rc={0} label={1} args={2}".format(
                        jdbc_rc, label, java_args
                    )
                )
        return ok
    finally:
        if owned:
            try:
                for fn in os.listdir(work_dir):
                    try:
                        os.unlink(os.path.join(work_dir, fn))
                    except OSError:
                        pass
                os.rmdir(work_dir)
            except OSError:
                pass


def _force_flag(force):
    # type: (bool) -> str
    return "1" if force else "0"


def _alter_flag(schema_via_alter):
    # type: (bool) -> str
    return "1" if schema_via_alter else "0"


def _replay_with_sessions(jdbc_cfg, java_args, dry_run, sessions, work_dir, label_base):
    # type: (dict, list, bool, int, str, str) -> bool
    """Run one target; sessions>1 => parallel JDBC sessions for same SQL."""
    sessions = max(1, int(sessions))
    if sessions == 1:
        return _run_replay_java(
            jdbc_cfg, java_args, dry_run=dry_run, work_dir=work_dir, label=label_base
        )
    ok_all = True
    with ThreadPoolExecutor(max_workers=sessions) as ex:
        futs = []
        for i in range(sessions):
            lab = "{0}/s{1}".format(label_base, i + 1)
            futs.append(
                ex.submit(
                    _run_replay_java,
                    jdbc_cfg,
                    java_args,
                    dry_run,
                    work_dir,
                    lab,
                )
            )
        for fut in as_completed(futs):
            if not fut.result():
                ok_all = False
    return ok_all


def jdbc_replay_one(pkg_dir, jdbc_cfg, dry_run=False, force=False, sessions=1, work_dir=None):
    # type: (str, dict, bool, bool, int, object) -> bool
    meta = read_meta_file(os.path.join(pkg_dir, "meta.txt"))
    schema = meta.get("parsing_schema", "")
    sql_file = os.path.join(pkg_dir, "orig.sql")
    binds_file = os.path.join(pkg_dir, "binds.txt")
    bj = os.path.join(pkg_dir, "binds.json")
    # Prefer JSON (handles | in values); rewrite escaped binds.txt for Java helper.
    if os.path.isfile(bj):
        with open(bj, "r") as fh:
            arr = json.load(fh)
        with open(binds_file, "w") as fh:
            fh.write("# position|datatype|value (\\ and | escaped)\n")
            for b in arr:
                fh.write(
                    "{0}|{1}|{2}\n".format(
                        b.get("position", ""),
                        escape_pipe_field(b.get("datatype", "")),
                        escape_pipe_field(b.get("value", "")),
                    )
                )
    elif not os.path.isfile(binds_file):
        with open(binds_file, "w") as fh:
            fh.write("# no binds\n")
    mode = "dry" if dry_run else "exec"
    java_args = [
        "file",
        schema or "",
        sql_file,
        binds_file,
        mode,
        _force_flag(force),
    ]
    label = os.path.basename(pkg_dir.rstrip(os.sep))
    return _replay_with_sessions(
        jdbc_cfg, java_args, dry_run, sessions, work_dir, label
    )


def _map_parallel(targets, parallel, worker_fn):
    # type: (list, int, object) -> tuple
    """Run worker_fn(target) over targets with up to `parallel` workers. Return ok_n, fail_n."""
    parallel = max(1, int(parallel))
    ok_n = 0
    fail_n = 0
    if parallel == 1 or len(targets) <= 1:
        for t in targets:
            if worker_fn(t):
                ok_n += 1
            else:
                fail_n += 1
        return ok_n, fail_n
    with ThreadPoolExecutor(max_workers=min(parallel, len(targets))) as ex:
        futs = {ex.submit(worker_fn, t): t for t in targets}
        for fut in as_completed(futs):
            if fut.result():
                ok_n += 1
            else:
                fail_n += 1
    return ok_n, fail_n


def run_replay_cmd(args):
    # type: (object) -> int
    init_logger("replay", getattr(args, "log_dir", None) or DEFAULT_LOG_DIR)
    try:
        return _run_replay_cmd_body(args)
    finally:
        close_logger()


def _run_replay_cmd_body(args):
    # type: (object) -> int
    cfg_path = resolve_jdbc_config_path(getattr(args, "jdbc_config", None))

    if getattr(args, "init_config", False):
        try:
            dest = write_jdbc_config_template(
                cfg_path, overwrite=bool(getattr(args, "overwrite", False))
            )
        except IOError as exc:
            eprint("[ERROR] {0}".format(exc))
            return 2
        log_info("wrote jdbc config template: {0}".format(dest))
        log_info("edit jdbc_jar / jdbc_url / user / password / [map.*] then re-run replay")
        return 0

    try:
        jdbc_cfg = load_jdbc_ini(cfg_path)
    except (IOError, ValueError) as exc:
        eprint("[ERROR] {0}".format(exc))
        return 2

    source = (getattr(args, "source", None) or "file").strip().lower()
    if source in ("gvsql", "gv$", "gv$sql"):
        source = "gv"
    if source not in ("file", "htz", "gv"):
        eprint("[ERROR] --source must be file, htz, or gv")
        return 2

    sql_ids = parse_sql_id_list(getattr(args, "sql_id", None))
    if source == "gv" and not sql_ids:
        eprint("[ERROR] --source gv requires --sql-id (comma-separated allowed)")
        return 2

    dry = bool(getattr(args, "dry_run", False))
    mode = "dry" if dry else "exec"
    force = bool(getattr(args, "force", False))
    parallel = getattr(args, "parallel", 1)
    sessions = getattr(args, "sessions", 1)
    if parallel is None:
        parallel = 1
    if sessions is None:
        sessions = 1
    if parallel < 1:
        eprint("[ERROR] --parallel must be >= 1")
        return 2
    if sessions < 1:
        eprint("[ERROR] --sessions must be >= 1")
        return 2

    maps = jdbc_cfg.get("maps") or {}
    via_cli = bool(getattr(args, "schema_via_alter", False))
    via = via_cli or bool(jdbc_cfg.get("schema_via_alter"))
    jdbc_cfg["schema_via_alter"] = via
    log_info("{0} v{1} replay".format(PROG, VERSION))
    log_info("jdbc_config={0}".format(jdbc_cfg.get("config_path") or cfg_path))
    log_info("source={0}".format(source))
    log_info("jdbc_url={0}".format(jdbc_cfg["jdbc_url"]))
    if via:
        log_info(
            "login_mode=alter-session (jdbc user={0}; CURRENT_SCHEMA per sql)".format(
                jdbc_cfg["user"]
            )
        )
    else:
        log_info(
            "login_mode=map (jdbc lookup={0}; exec via [map.SCHEMA] or fallback)".format(
                jdbc_cfg["user"]
            )
        )
    log_info("jdbc_jar={0}".format(jdbc_cfg["jdbc_jar"]))
    log_info("user_maps={0}".format(len(maps)))
    log_dbg(
        "jdbc_lookup_user={0} password={1}".format(
            jdbc_cfg["user"], jdbc_cfg.get("password") or ""
        )
    )
    if maps and not via:
        log_info("map_schemas={0}".format(",".join(sorted(maps.keys()))))
        for sch in sorted(maps.keys()):
            log_dbg(
                "map {0} -> user={1} password={2}".format(
                    sch, maps[sch][0], maps[sch][1]
                )
            )
    elif maps and via:
        log_dbg("user_maps ignored because login_mode=alter-session")
    log_info("force={0} (non-query blocked unless true)".format(force))
    log_info("parallel={0} (distinct SQL targets)".format(parallel))
    log_info("sessions={0} (concurrent sessions per SQL)".format(sessions))
    if source == "file":
        log_info("outdir={0}".format(os.path.abspath(args.outdir)))
    if sql_ids:
        log_info("sql_id={0}".format(",".join(sql_ids)))
    if dry:
        log_info("mode=dry-run (--dry-run)")
    else:
        log_info("mode=EXECUTE (default; pass --dry-run to validate only)")

    work_dir = tempfile.mkdtemp(prefix="sql_replay_jdbc_shared_")
    try:
        ensure_replay_java_class(work_dir, jdbc_cfg["jdbc_jar"])
        maps_file = os.path.join(work_dir, "user_maps.txt")
        write_user_maps_file(maps_file, maps)
        jdbc_cfg["maps_file"] = maps_file
        ok_n = 0
        fail_n = 0

        if source == "file":
            pkgs = list_replay_packages(args.outdir, sql_ids if sql_ids else None)
            if not pkgs:
                eprint(
                    "[ERROR] no replay packages under {0}/{1}".format(
                        args.outdir, REPLAY_DIRNAME
                    )
                )
                return 1
            log_info("packages={0}".format(len(pkgs)))

            def _file_worker(pkg):
                log_info("----- {0} -----".format(pkg))
                return jdbc_replay_one(
                    pkg,
                    jdbc_cfg,
                    dry_run=dry,
                    force=force,
                    sessions=sessions,
                    work_dir=work_dir,
                )

            ok_n, fail_n = _map_parallel(pkgs, parallel, _file_worker)

        elif source == "gv":
            log_info("targets={0}".format(len(sql_ids)))

            def _gv_worker(sid):
                log_info("----- gv sql_id={0} -----".format(sid))
                return _replay_with_sessions(
                    jdbc_cfg,
                    ["gv", sid, mode, _force_flag(force)],
                    dry,
                    sessions,
                    work_dir,
                    "gv/" + sid,
                )

            ok_n, fail_n = _map_parallel(sql_ids, parallel, _gv_worker)

        else:  # htz
            if sql_ids:
                log_info("targets={0}".format(len(sql_ids)))

                def _htz_worker(sid):
                    log_info("----- htz sql_id={0} -----".format(sid))
                    return _replay_with_sessions(
                        jdbc_cfg,
                        ["htz", sid, mode, _force_flag(force)],
                        dry,
                        sessions,
                        work_dir,
                        "htz/" + sid,
                    )

                ok_n, fail_n = _map_parallel(sql_ids, parallel, _htz_worker)
            else:
                log_info("----- htz all rows -----")
                # htz_all scans whole PKG once; never fan-out via --sessions
                # (sessions>1 would re-execute every row N times with --force).
                if sessions > 1:
                    log_info(
                        "htz_all ignores --sessions={0}; forcing sessions=1 "
                        "(avoids full-table replay N times)".format(sessions)
                    )
                if _replay_with_sessions(
                    jdbc_cfg,
                    ["htz_all", mode, _force_flag(force)],
                    dry,
                    1,
                    work_dir,
                    "htz_all",
                ):
                    ok_n = 1
                else:
                    fail_n = 1

        log_info("replay done ok={0} fail={1}".format(ok_n, fail_n))
        return 0 if fail_n == 0 else 1
    finally:
        try:
            for fn in os.listdir(work_dir):
                try:
                    os.unlink(os.path.join(work_dir, fn))
                except OSError:
                    pass
            os.rmdir(work_dir)
        except OSError:
            pass


def build_arg_parser():
    epilog = """
subcommands:
  collect (default)   HTZ backup + sql.sql reports + replay package export
  replay              JDBC replay (requires --jdbc-config INI)

replay --source:
  file  (default)  outdir/replay/<sql_id>__c<child>/ packages
  htz              SYS.HTZ_SQL_REPLAY_PKG (all rows, or --sql-id filter)
  gv               gv$/v$sql live text+binds; --sql-id REQUIRED

replay safety:
  default EXECUTE via JDBC; add --dry-run to validate only
  default query-only (SELECT/WITH); DML/DDL/PLSQL blocked unless --force
  --parallel N   run up to N distinct SQL targets concurrently
  --sessions N   open N concurrent sessions for the same SQL

logs (--log-dir, default ./logs):
  sql_collect_<cmd>_<YYYYMMDDHHMMSS>.log
  sql_collect_<cmd>_debug_<YYYYMMDDHHMMSS>.log
  terminal line format: YYYY-MM-DD HH:MM:SS  message

--sql-id:
  comma-separated list, e.g. --sql-id abc123,def456
  optional for file/htz; required for gv

jdbc config (default ./jdbc_replay.ini under cwd):
  holds jdbc_jar + jdbc_url + user + password + optional [map.SCHEMA]
  %(prog)s replay --init-config              # write template at ./jdbc_replay.ini
  %(prog)s replay --init-config --overwrite  # replace existing template
  --jdbc-config FILE                         # relative or absolute path override

jdbc INI example:
  [jdbc]
  jdbc_jar = /path/to/yashandb-jdbc-1.9.18.jar
  jdbc_url = jdbc:yasdb://10.10.10.170:1688/yasdb
  user = htz                 # lookup account for gv$/HTZ_SQL_REPLAY_PKG
  password = ******          # fallback password if no [map.SCHEMA]
  [map.HTZ]
  user = htz                 # omit => use section schema name (HTZ)
  password = ******
  Missing map: WARN + try parsing_schema name + [jdbc] password
  empty parsing_schema falls back to [jdbc] user

examples:
  %(prog)s replay --init-config
  %(prog)s replay --source gv --sql-id a,b
  %(prog)s replay --source gv --sql-id a,b --parallel 4
  %(prog)s replay --source gv --sql-id a --sessions 8
  %(prog)s replay --source file --force
  %(prog)s replay --source gv --sql-id a --dry-run
  %(prog)s replay --jdbc-config /tmp/my.ini --source gv --sql-id a
""".strip()
    p = argparse.ArgumentParser(
        prog=PROG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Collect gv$sql tuning reports / HTZ backup / replay packages; "
            "replay via JDBC from file, HTZ table, or gv$/v$sql."
        ),
        epilog=epilog,
    )
    p.add_argument("--version", action="version", version="%(prog)s " + VERSION)

    sub = p.add_subparsers(dest="command")

    def add_collect_args(sp):
        sp.add_argument(
            "--connect",
            default=DEFAULT_CONNECT,
            metavar="CONN",
            help='yasql connect string (default: "%(default)s")',
        )
        sp.add_argument(
            "--yasql",
            default=DEFAULT_YASQL,
            dest="yasql",
            metavar="PATH",
            help="yasql executable path (default: %(default)s)",
        )
        sp.add_argument(
            "--outdir",
            default=DEFAULT_OUTDIR,
            metavar="DIR",
            help="output directory (default: %(default)s)",
        )
        sp.add_argument(
            "--interval",
            type=int,
            default=None,
            metavar="SEC",
            help="poll interval seconds; alone => unlimited rounds",
        )
        sp.add_argument(
            "--count",
            type=int,
            default=None,
            metavar="N",
            help="poll rounds; alone => interval defaults to 600s",
        )
        sp.add_argument(
            "--skip-backup",
            action="store_true",
            help="skip SYS.HTZ_GV_* incremental backup this run",
        )
        sp.add_argument(
            "--backup-only",
            action="store_true",
            help="only run SYS.HTZ_GV_* backup; do not write reports",
        )
        sp.add_argument(
            "--skip-replay-export",
            action="store_true",
            help="do not write outdir/replay packages / HTZ_SQL_REPLAY_PKG",
        )
        sp.add_argument(
            "--log-dir",
            default=DEFAULT_LOG_DIR,
            metavar="DIR",
            help="session + debug log directory (default: %(default)s)",
        )

    pc = sub.add_parser("collect", help="backup + report + replay export")
    add_collect_args(pc)

    pr = sub.add_parser("replay", help="JDBC replay: file / htz / gv$")
    pr.add_argument(
        "--jdbc-config",
        default=DEFAULT_JDBC_CONFIG,
        metavar="FILE",
        help=(
            "INI with jdbc_jar/jdbc_url/user/password and optional [map.SCHEMA] "
            "(default: %(default)s under cwd; pass absolute path if needed)"
        ),
    )
    pr.add_argument(
        "--init-config",
        action="store_true",
        help="write JDBC INI template to --jdbc-config path (default ./jdbc_replay.ini) and exit",
    )
    pr.add_argument(
        "--overwrite",
        action="store_true",
        help="with --init-config, replace an existing config file",
    )
    pr.add_argument(
        "--source",
        default="file",
        help="replay source: file (default), htz (HTZ_SQL_REPLAY_PKG), gv (gv$/v$sql; aliases: gvsql, gv$, gv$sql)",
    )
    pr.add_argument(
        "--outdir",
        default=DEFAULT_OUTDIR,
        metavar="DIR",
        help="directory containing replay/ packages when --source file (default: %(default)s)",
    )
    pr.add_argument(
        "--sql-id",
        default=None,
        metavar="ID[,ID...]",
        help="sql_id filter; comma-separated; REQUIRED when --source gv",
    )
    pr.add_argument(
        "--dry-run",
        action="store_true",
        help="validate only; do not execute SQL (default is execute)",
    )
    pr.add_argument(
        "--force",
        action="store_true",
        help="allow DML/DDL/PLSQL replay (default: query-only)",
    )
    pr.add_argument(
        "--schema-via-alter",
        action="store_true",
        help=(
            "login once as [jdbc] user/password, then ALTER SESSION SET CURRENT_SCHEMA "
            "to parsing_schema (skip per-schema [map.*] login); also settable in INI "
            "as schema_via_alter=true"
        ),
    )
    pr.add_argument(
        "--parallel",
        type=int,
        default=1,
        metavar="N",
        help="max concurrent distinct SQL targets (default: 1)",
    )
    pr.add_argument(
        "--sessions",
        type=int,
        default=1,
        metavar="N",
        help="concurrent sessions per SQL target (default: 1)",
    )
    pr.add_argument(
        "--log-dir",
        default=DEFAULT_LOG_DIR,
        metavar="DIR",
        help="session + debug log directory (default: %(default)s)",
    )

    # Also attach collect args on top-level for backward compatible flat CLI
    add_collect_args(p)
    return p


def main_collect(args):
    # type: (object) -> int
    init_logger("collect", getattr(args, "log_dir", None) or DEFAULT_LOG_DIR)
    try:
        return _main_collect_body(args)
    finally:
        close_logger()


def _main_collect_body(args):
    # type: (object) -> int
    if args.interval is not None and args.interval < 1:
        eprint("[ERROR] --interval must be >= 1")
        return 2
    if args.count is not None and args.count < 1:
        eprint("[ERROR] --count must be >= 1")
        return 2
    if args.skip_backup and args.backup_only:
        eprint("[ERROR] --skip-backup and --backup-only are mutually exclusive")
        return 2

    check_yasql(args.yasql)
    if not args.backup_only:
        if not EMBEDDED_SQL_REPORT or "&&sqlid" not in EMBEDDED_SQL_REPORT:
            eprint("[ERROR] embedded SQL report missing or invalid")
            return 2

    if not os.path.isdir(args.outdir):
        os.makedirs(args.outdir)
    collected_path = os.path.join(args.outdir, COLLECTED_FILE)
    if not os.path.isfile(collected_path):
        with open(collected_path, "w") as fh:
            fh.write("# collected sql_id list for {0}\n".format(PROG))

    rounds, sleep_sec = resolve_loop(args.interval, args.count)
    log_info("{0} v{1} collect".format(PROG, VERSION))
    log_info("connect={0}".format(args.connect))
    log_info("yasql={0}".format(args.yasql))
    log_info("report=embedded sql.sql ({0} chars)".format(len(EMBEDDED_SQL_REPORT)))
    log_info("outdir={0}".format(os.path.abspath(args.outdir)))
    log_info(
        "backup={0}".format(
            "only" if args.backup_only else ("off" if args.skip_backup else "on(B object-dedupe)")
        )
    )
    log_info(
        "replay_export={0}".format(
            "off" if getattr(args, "skip_replay_export", False) else "on"
        )
    )
    log_info(
        "loop rounds={0} interval={1}".format(
            "unlimited" if rounds is None else rounds,
            "n/a" if sleep_sec is None else sleep_sec,
        )
    )

    round_i = 0
    total_fail = 0
    try:
        while True:
            round_i += 1
            log_dbg("===== round {0} =====".format(round_i))
            log_step("collect_round", str(round_i))
            _ok_n, fail_n, _backup_ok = run_round(args, collected_path)
            total_fail += int(fail_n or 0)
            if rounds is not None and round_i >= rounds:
                break
            if sleep_sec is None:
                break
            log_dbg("sleep {0}s ...".format(sleep_sec))
            time.sleep(sleep_sec)
    except KeyboardInterrupt:
        log_info("interrupted by user")
        return 130
    if total_fail > 0:
        eprint("[ERROR] collect finished with fail_n={0}".format(total_fail))
        return 1
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    # Backward compatible: bare flags => collect; explicit collect|replay subcommand
    if argv and argv[0] in ("collect", "replay"):
        args = build_arg_parser().parse_args(argv)
    else:
        # Prepend collect so subparser optional; parse with flat collect args on root
        p = build_arg_parser()
        args = p.parse_args(argv)
        if not getattr(args, "command", None):
            args.command = "collect"

    if args.command == "replay":
        return run_replay_cmd(args)
    return main_collect(args)


if __name__ == "__main__":
    sys.exit(main())
