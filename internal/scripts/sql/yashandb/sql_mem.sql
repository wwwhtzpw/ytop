-- File Name: sql_mem.sql
-- Purpose: YashanDB shared-pool SQL memory share by SCHEMA/SQL_ID/norm (GV$SQLAREA, YAC)
-- Created: 20260809 by huangtingzhong
-- Updated: 20260809 by huangtingzhong (TEXT 100 chars; NORM section sample SQL_ID)
--
-- Notes:
--   - Shared pool is per-instance; uses GV$SQLAREA / GV$SGASTAT for full YAC cluster.
--   - LITERAL_HASH_VALUE / FORCE_MATCHING_SIGNATURE are not usable on 23.5 lab
--     (null/zero); NORM_SQL approximates literal-stripped grouping.
--   - pct = share of cluster SQLAREA SHARABLE_MEM total (not whole SGA).
-- Params:
--   topn : top N rows for SQL_ID / NORM sections (Enter=15)

COL i         FOR A2
COL pool_mb   FOR A10
COL sql_cnt   FOR A8
COL nodes     FOR A5
COL share_mb  FOR A10
COL pers_mb   FOR A10
COL schema    FOR A16
COL mem_kb    FOR A10
COL pct       FOR A7
COL rn        FOR A3
COL sql_id    FOR A13
COL text      FOR A100


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Shared-pool SQL memory share (GV$SQLAREA, full YAC cluster)            |
PROMPT | topn : Enter=15                                                        |
PROMPT | Sections: INST pool | SCHEMA% | SQL_ID% | NORM_SQL% (literal flood)    |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT topn PROMPT 'Enter topn (Enter=15): '

PROMPT
PROMPT === A) Per-instance pool context (GV$SGASTAT sql pool + GV$SQLAREA) ===
WITH sqlarea_i AS (
    SELECT a.INST_ID AS i,
           COUNT(*) AS sql_cnt,
           NVL(SUM(a.SHARABLE_MEM), 0) AS share_bytes,
           NVL(SUM(a.PERSISTENT_MEM), 0) AS pers_bytes
      FROM GV$SQLAREA a
     GROUP BY a.INST_ID
),
sga_i AS (
    SELECT s.INST_ID AS i,
           NVL(SUM(s.BYTES), 0) AS pool_bytes
      FROM GV$SGASTAT s
     WHERE UPPER(s.POOL) LIKE '%SHARE%'
       AND UPPER(s.NAME) = 'SQL POOL'
     GROUP BY s.INST_ID
)
SELECT TO_CHAR(a.i) AS i,
       TO_CHAR(ROUND(NVL(s.pool_bytes, 0) / 1024 / 1024, 2)) AS pool_mb,
       TO_CHAR(NVL(a.sql_cnt, 0)) AS sql_cnt,
       TO_CHAR(ROUND(NVL(a.share_bytes, 0) / 1024 / 1024, 2)) AS share_mb,
       TO_CHAR(ROUND(NVL(a.pers_bytes, 0) / 1024 / 1024, 2)) AS pers_mb
  FROM sqlarea_i a
  LEFT JOIN sga_i s ON s.i = a.i
 ORDER BY a.i;

PROMPT
PROMPT === B) By SCHEMA share of SHARABLE_MEM ===
WITH base AS (
    SELECT a.INST_ID,
           a.SQL_ID,
           NVL(a.PARSING_SCHEMA_NAME, 'UNKNOWN') AS schema_name,
           NVL(a.SHARABLE_MEM, 0) AS share_bytes
      FROM GV$SQLAREA a
),
agg AS (
    SELECT schema_name,
           COUNT(DISTINCT SQL_ID) AS sql_cnt,
           COUNT(DISTINCT INST_ID) AS nodes,
           SUM(share_bytes) AS mem
      FROM base
     GROUP BY schema_name
),
tot AS (
    SELECT NVL(SUM(mem), 0) AS t_mem FROM agg
)
SELECT a.schema_name AS schema,
       TO_CHAR(a.sql_cnt) AS sql_cnt,
       TO_CHAR(a.nodes) AS nodes,
       TO_CHAR(ROUND(a.mem / 1024, 1)) AS mem_kb,
       TO_CHAR(ROUND(100 * a.mem / NULLIF(t.t_mem, 0), 2)) AS pct
  FROM agg a, tot t
 ORDER BY a.mem DESC NULLS LAST, a.schema_name;

PROMPT
PROMPT === C) By SQL_ID share of SHARABLE_MEM (TOP) ===
WITH base AS (
    SELECT a.INST_ID,
           a.SQL_ID,
           NVL(a.PARSING_SCHEMA_NAME, 'UNKNOWN') AS schema_name,
           NVL(a.SHARABLE_MEM, 0) AS share_bytes,
           SUBSTR(REPLACE(REPLACE(a.SQL_TEXT, CHR(10), ' '), CHR(13), ' '), 1, 100) AS sql_text
      FROM GV$SQLAREA a
),
agg AS (
    SELECT SQL_ID,
           COUNT(DISTINCT INST_ID) AS nodes,
           SUM(share_bytes) AS mem,
           MAX(schema_name) AS schema_name,
           MAX(sql_text) AS sql_text
      FROM base
     GROUP BY SQL_ID
),
tot AS (
    SELECT NVL(SUM(mem), 0) AS t_mem FROM agg
),
ranked AS (
    SELECT a.*,
           ROW_NUMBER() OVER (ORDER BY a.mem DESC NULLS LAST, a.SQL_ID) AS rn
      FROM agg a
)
SELECT TO_CHAR(r.rn) AS rn,
       r.SQL_ID AS sql_id,
       TO_CHAR(r.nodes) AS nodes,
       TO_CHAR(ROUND(r.mem / 1024, 1)) AS mem_kb,
       TO_CHAR(ROUND(100 * r.mem / NULLIF(t.t_mem, 0), 2)) AS pct,
       r.schema_name AS schema,
       r.sql_text AS text
  FROM ranked r, tot t
 WHERE r.rn <= CASE
                   WHEN NULLIF(TRIM('&&topn'), '') IS NULL THEN 15
                   ELSE TO_NUMBER(TRIM('&&topn'))
               END
 ORDER BY r.rn;

PROMPT
PROMPT === D) By NORM_SQL share (literal-stripped; catches bind-less flood) ===
WITH base AS (
    SELECT a.INST_ID,
           a.SQL_ID,
           NVL(a.PARSING_SCHEMA_NAME, 'UNKNOWN') AS schema_name,
           NVL(a.SHARABLE_MEM, 0) AS share_bytes,
           SUBSTR(REPLACE(REPLACE(a.SQL_TEXT, CHR(10), ' '), CHR(13), ' '), 1, 100) AS sql_text,
           REGEXP_REPLACE(
               REGEXP_REPLACE(
                   REGEXP_REPLACE(SUBSTR(a.SQL_TEXT, 1, 4000), '''[^'']*''', '''#'''),
                   '[0-9]+', '#'),
               '[[:space:]]+', ' ') AS norm_sql
      FROM GV$SQLAREA a
),
agg AS (
    SELECT norm_sql,
           COUNT(DISTINCT SQL_ID) AS sql_cnt,
           COUNT(DISTINCT INST_ID) AS nodes,
           SUM(share_bytes) AS mem,
           MAX(schema_name) AS schema_name,
           MIN(SQL_ID) AS sql_id,
           MAX(sql_text) AS sql_text
      FROM base
     GROUP BY norm_sql
),
tot AS (
    SELECT NVL(SUM(mem), 0) AS t_mem FROM agg
),
ranked AS (
    SELECT a.*,
           ROW_NUMBER() OVER (ORDER BY a.mem DESC NULLS LAST, a.norm_sql) AS rn
      FROM agg a
)
SELECT TO_CHAR(r.rn) AS rn,
       TO_CHAR(r.sql_cnt) AS sql_cnt,
       TO_CHAR(r.nodes) AS nodes,
       TO_CHAR(ROUND(r.mem / 1024, 1)) AS mem_kb,
       TO_CHAR(ROUND(100 * r.mem / NULLIF(t.t_mem, 0), 2)) AS pct,
       r.sql_id AS sql_id,
       r.schema_name AS schema,
       r.sql_text AS text
  FROM ranked r, tot t
 WHERE r.rn <= CASE
                   WHEN NULLIF(TRIM('&&topn'), '') IS NULL THEN 15
                   ELSE TO_NUMBER(TRIM('&&topn'))
               END
 ORDER BY r.rn;
