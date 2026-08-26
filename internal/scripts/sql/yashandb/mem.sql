-- File Name: mem.sql
-- Purpose: YashanDB memory params, SGA components, shared-pool SQL share (GV$, YAC)
-- Created: 20260809 by huangtingzhong
-- Updated: 20260809 by huangtingzhong (add MEX_POOL param/components)
--
-- Notes:
--   - No ACCEPT; edit FETCH FIRST N for dict / SQL TOP rows.
--   - pct = percent of host PHYSICAL_MEMORY_BYTES (v$osstat).
--   - SQL pool sections mirror sql_mem.sql (SCHEMA / SQL_ID / NORM_SQL).
--   - GV$SGA column is SIZE; quote "SIZE" where needed.

COL i          FOR A2
COL name       FOR A40
COL value      FOR A16
COL mb         FOR A10
COL pct        FOR A7
COL pct_s      FOR A7
COL phy_mb     FOR A10
COL pool       FOR A14
COL component  FOR A24
COL param_mb   FOR A10
COL sga_mb     FOR A10
COL typ        FOR A4
COL cnt        FOR A8
COL gets       FOR A12
COL phy_rd     FOR A10
COL resident   FOR A8
COL sql_cnt    FOR A8
COL nodes      FOR A5
COL mem_kb     FOR A10
COL share_mb   FOR A10
COL pers_mb    FOR A10
COL rn         FOR A3
COL sql_id     FOR A13
COL schema     FOR A14
COL text       FOR A100
COL hold_mb    FOR A10
COL using_mb   FOR A10
COL unused_mb  FOR A10
COL alloc_mb   FOR A12
COL free_mb    FOR A12

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Memory overview + shared-pool SQL share (GV$, YAC)                     |
PROMPT | pct = percent of host physical memory (v$osstat)                       |
PROMPT +------------------------------------------------------------------------+
PROMPT

PROMPT === A) Memory-related parameters (mb + pct of physical) ===
WITH phy AS (
    SELECT value AS phy_bytes
      FROM v$osstat
     WHERE UPPER(stat_name) = 'PHYSICAL_MEMORY_BYTES'
),
p AS (
    SELECT name,
           value,
           CASE
               WHEN REGEXP_LIKE(value, '^[0-9]+$') THEN TO_NUMBER(value)
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+G$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'G$', '')) * 1024 * 1024 * 1024
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+M$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'M$', '')) * 1024 * 1024
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+K$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'K$', '')) * 1024
               ELSE NULL
           END AS bytes
      FROM v$parameter
     -- memory size knobs only (exclude file/trace/swap/block-size style params)
     WHERE (UPPER(name) LIKE '%_SIZE'
         OR UPPER(name) LIKE '%_CAPACITY'
         OR UPPER(name) LIKE '%MEMORY_SIZE%')
       AND UPPER(name) NOT LIKE '%SCAN_ROWS%'
       AND UPPER(name) NOT LIKE '%PERCENT%'
       AND UPPER(name) NOT LIKE '%POLICY%'
       AND UPPER(name) NOT LIKE '%FILE%'
       AND UPPER(name) NOT LIKE '%FLASHBACK%'
       AND UPPER(name) NOT LIKE '%TRACE%'
       AND UPPER(name) NOT LIKE '%SWAP%'
       AND UPPER(name) NOT LIKE '%BULK_SIZE%'
       AND UPPER(name) NOT LIKE '%WINDOW_SIZE%'
       AND UPPER(name) <> 'DB_BLOCK_SIZE'
)
SELECT p.name,
       p.value,
       TO_CHAR(ROUND(p.bytes / 1024 / 1024, 2)) AS mb,
       TO_CHAR(ROUND(100 * p.bytes / NULLIF(phy.phy_bytes, 0), 2)) AS pct,
       TO_CHAR(ROUND(phy.phy_bytes / 1024 / 1024, 2)) AS phy_mb
  FROM p, phy
 ORDER BY p.bytes DESC NULLS LAST, p.name;

PROMPT
PROMPT === B) GV$SGA components (mb + pct of physical / of instance SGA) ===
WITH phy AS (
    SELECT value AS phy_bytes
      FROM v$osstat
     WHERE UPPER(stat_name) = 'PHYSICAL_MEMORY_BYTES'
),
sga AS (
    SELECT inst_id,
           name,
           "SIZE" AS bytes,
           SUM("SIZE") OVER (PARTITION BY inst_id) AS sga_bytes
      FROM gv$sga
)
SELECT TO_CHAR(s.inst_id) AS i,
       s.name,
       TO_CHAR(ROUND(s.bytes / 1024 / 1024, 2)) AS mb,
       TO_CHAR(ROUND(100 * s.bytes / NULLIF(phy.phy_bytes, 0), 2)) AS pct,
       TO_CHAR(ROUND(100 * s.bytes / NULLIF(s.sga_bytes, 0), 2)) AS pct_s,
       TO_CHAR(ROUND(phy.phy_bytes / 1024 / 1024, 2)) AS phy_mb
  FROM sga s, phy
 ORDER BY s.inst_id, s.bytes DESC;

PROMPT
PROMPT === C) Key param vs GV$SGA (mb + pct of physical) ===
WITH phy AS (
    SELECT value AS phy_bytes
      FROM v$osstat
     WHERE UPPER(stat_name) = 'PHYSICAL_MEMORY_BYTES'
),
p AS (
    SELECT name,
           CASE
               WHEN REGEXP_LIKE(value, '^[0-9]+$') THEN TO_NUMBER(value)
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+G$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'G$', '')) * 1024 * 1024 * 1024
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+M$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'M$', '')) * 1024 * 1024
               ELSE NULL
           END AS bytes
      FROM v$parameter
     WHERE UPPER(name) IN (
           'DATA_BUFFER_SIZE', 'SHARE_POOL_SIZE', 'LARGE_POOL_SIZE',
           'REDO_BUFFER_SIZE', 'VM_BUFFER_SIZE', 'DBWR_BUFFER_SIZE',
           'WORK_AREA_POOL_SIZE', 'CURSOR_POOL_SIZE',
           'MEX_POOL_SIZE', 'PQ_POOL_SIZE'
     )
)
SELECT p.name AS component,
       TO_CHAR(ROUND(p.bytes / 1024 / 1024, 2)) AS param_mb,
       TO_CHAR(ROUND(s."SIZE" / 1024 / 1024, 2)) AS sga_mb,
       TO_CHAR(ROUND(100 * p.bytes / NULLIF(phy.phy_bytes, 0), 2)) AS pct,
       TO_CHAR(ROUND(phy.phy_bytes / 1024 / 1024, 2)) AS phy_mb
  FROM p
  CROSS JOIN phy
  LEFT JOIN v$sga s ON (
         (UPPER(p.name) = 'DATA_BUFFER_SIZE' AND LOWER(s.name) = 'data buffer')
      OR (UPPER(p.name) = 'SHARE_POOL_SIZE' AND LOWER(s.name) = 'share pool')
      OR (UPPER(p.name) = 'LARGE_POOL_SIZE' AND LOWER(s.name) = 'large pool')
      OR (UPPER(p.name) = 'REDO_BUFFER_SIZE' AND LOWER(s.name) = 'redo buffer')
      OR (UPPER(p.name) = 'VM_BUFFER_SIZE' AND LOWER(s.name) = 'temporary buffer')
      OR (UPPER(p.name) = 'DBWR_BUFFER_SIZE' AND LOWER(s.name) = 'dbwr buffer')
      -- MEX/PQ have no same-name row in GV$SGA; sga_mb stays null
  )
 ORDER BY p.bytes DESC NULLS LAST, p.name;

PROMPT
PROMPT === D) GV$SGASTAT SHARE/LARGE detail (mb + pct of physical) ===
WITH phy AS (
    SELECT value AS phy_bytes
      FROM v$osstat
     WHERE UPPER(stat_name) = 'PHYSICAL_MEMORY_BYTES'
)
SELECT TO_CHAR(g.inst_id) AS i,
       g.pool,
       g.name,
       TO_CHAR(ROUND(g.bytes / 1024 / 1024, 2)) AS mb,
       TO_CHAR(ROUND(100 * g.bytes / NULLIF(phy.phy_bytes, 0), 2)) AS pct
  FROM gv$sgastat g, phy
 ORDER BY g.inst_id, g.pool, g.bytes DESC;

PROMPT
PROMPT === E) Data buffer (GV$BUFFER_POOL + STATISTICS) ===
WITH phy AS (
    SELECT value AS phy_bytes
      FROM v$osstat
     WHERE UPPER(stat_name) = 'PHYSICAL_MEMORY_BYTES'
)
SELECT TO_CHAR(b.inst_id) AS i,
       s.name,
       TO_CHAR(ROUND(b."SIZE" / 1024 / 1024, 2)) AS mb,
       TO_CHAR(ROUND(100 * b."SIZE" / NULLIF(phy.phy_bytes, 0), 2)) AS pct,
       TO_CHAR(s.num_total) AS cnt,
       TO_CHAR(s.num_resident) AS resident,
       TO_CHAR(s.db_block_gets) AS gets,
       TO_CHAR(s.physical_reads) AS phy_rd
  FROM gv$buffer_pool b
  JOIN gv$buffer_pool_statistics s
    ON s.inst_id = b.inst_id
   AND s.id = b.id
  CROSS JOIN phy
 ORDER BY b.inst_id, s.name;

PROMPT
PROMPT === F) Dict cache TOP (edit FETCH FIRST N) ===
SELECT TO_CHAR(inst_id) AS i,
       TO_CHAR(type) AS typ,
       name,
       TO_CHAR(ROUND(memory_context_used / 1024 / 1024, 2)) AS mb
  FROM gv$dict_cache
 ORDER BY memory_context_used DESC NULLS LAST
 FETCH FIRST 20 ROWS ONLY;

PROMPT
PROMPT === G) MEX pool (MEX_POOL_SIZE + GV$MEX_BASE/EDEN/AREA + modules) ===
PROMPT --- G1) param vs current hold/using ---
WITH phy AS (
    SELECT value AS phy_bytes
      FROM v$osstat
     WHERE UPPER(stat_name) = 'PHYSICAL_MEMORY_BYTES'
),
param AS (
    SELECT CASE
               WHEN REGEXP_LIKE(value, '^[0-9]+$') THEN TO_NUMBER(value)
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+G$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'G$', '')) * 1024 * 1024 * 1024
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+M$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'M$', '')) * 1024 * 1024
               ELSE NULL
           END AS bytes
      FROM v$parameter
     WHERE UPPER(name) = 'MEX_POOL_SIZE'
)
SELECT 'MEX_POOL_SIZE' AS name,
       TO_CHAR(ROUND(p.bytes / 1024 / 1024, 2)) AS hold_mb,
       CAST(NULL AS VARCHAR(10)) AS using_mb,
       CAST(NULL AS VARCHAR(10)) AS unused_mb,
       TO_CHAR(ROUND(100 * p.bytes / NULLIF(phy.phy_bytes, 0), 2)) AS pct
  FROM param p, phy
UNION ALL
SELECT 'mex_base',
       TO_CHAR(ROUND(SUM(b.hold_size) / 1024 / 1024, 2)),
       TO_CHAR(ROUND(SUM(b.using_size) / 1024 / 1024, 2)),
       TO_CHAR(ROUND(SUM(b.unused_size) / 1024 / 1024, 2)),
       TO_CHAR(ROUND(100 * SUM(b.hold_size) / NULLIF(MAX(phy.phy_bytes), 0), 2))
  FROM gv$mex_base b, phy
UNION ALL
SELECT 'mex_eden',
       TO_CHAR(ROUND(SUM(e.hold_size) / 1024 / 1024, 2)),
       TO_CHAR(ROUND(SUM(e.using_size) / 1024 / 1024, 2)),
       TO_CHAR(ROUND(SUM(e.unused_size) / 1024 / 1024, 2)),
       TO_CHAR(ROUND(100 * SUM(e.hold_size) / NULLIF(MAX(phy.phy_bytes), 0), 2))
  FROM gv$mex_eden e, phy
UNION ALL
SELECT 'mex_area',
       TO_CHAR(ROUND(SUM(a.hold_size) / 1024 / 1024, 2)),
       TO_CHAR(ROUND(SUM(a.using_size) / 1024 / 1024, 2)),
       TO_CHAR(ROUND(SUM(a.unused_size) / 1024 / 1024, 2)),
       TO_CHAR(ROUND(100 * SUM(a.hold_size) / NULLIF(MAX(phy.phy_bytes), 0), 2))
  FROM gv$mex_area a, phy;

PROMPT --- G2) MEX modules (lifetime alloc/free; not current RSS) ---
SELECT TO_CHAR(inst_id) AS i,
       name,
       TO_CHAR(ROUND(total_alloc_size / 1024 / 1024, 2)) AS alloc_mb,
       TO_CHAR(ROUND(total_free_size / 1024 / 1024, 2)) AS free_mb
  FROM gv$mex_pool_module
 ORDER BY total_alloc_size DESC;

PROMPT
PROMPT === H) Shared pool SQLAREA by instance (from sql_mem) ===
SELECT TO_CHAR(a.inst_id) AS i,
       TO_CHAR(COUNT(*)) AS sql_cnt,
       TO_CHAR(ROUND(SUM(a.sharable_mem) / 1024 / 1024, 2)) AS share_mb,
       TO_CHAR(ROUND(SUM(a.persistent_mem) / 1024 / 1024, 2)) AS pers_mb
  FROM gv$sqlarea a
 GROUP BY a.inst_id
 ORDER BY a.inst_id;

PROMPT
PROMPT === I) Shared pool by SCHEMA share of SHARABLE_MEM ===
WITH base AS (
    SELECT inst_id,
           sql_id,
           NVL(parsing_schema_name, 'UNKNOWN') AS schema_name,
           NVL(sharable_mem, 0) AS share_bytes
      FROM gv$sqlarea
),
agg AS (
    SELECT schema_name,
           COUNT(DISTINCT sql_id) AS sql_cnt,
           COUNT(DISTINCT inst_id) AS nodes,
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
PROMPT === J) Shared pool by SQL_ID TOP (edit N=15) ===
WITH base AS (
    SELECT inst_id,
           sql_id,
           NVL(parsing_schema_name, 'UNKNOWN') AS schema_name,
           NVL(sharable_mem, 0) AS share_bytes,
           SUBSTR(REPLACE(REPLACE(sql_text, CHR(10), ' '), CHR(13), ' '), 1, 100) AS sql_text
      FROM gv$sqlarea
),
agg AS (
    SELECT sql_id,
           COUNT(DISTINCT inst_id) AS nodes,
           SUM(share_bytes) AS mem,
           MAX(schema_name) AS schema_name,
           MAX(sql_text) AS sql_text
      FROM base
     GROUP BY sql_id
),
tot AS (
    SELECT NVL(SUM(mem), 0) AS t_mem FROM agg
),
ranked AS (
    SELECT a.*,
           ROW_NUMBER() OVER (ORDER BY a.mem DESC NULLS LAST, a.sql_id) AS rn
      FROM agg a
)
SELECT TO_CHAR(r.rn) AS rn,
       r.sql_id AS sql_id,
       TO_CHAR(r.nodes) AS nodes,
       TO_CHAR(ROUND(r.mem / 1024, 1)) AS mem_kb,
       TO_CHAR(ROUND(100 * r.mem / NULLIF(t.t_mem, 0), 2)) AS pct,
       r.schema_name AS schema,
       r.sql_text AS text
  FROM ranked r, tot t
 WHERE r.rn <= 15
 ORDER BY r.rn;

PROMPT
PROMPT === K) Shared pool by NORM_SQL TOP (literal-stripped; edit N=15) ===
WITH base AS (
    SELECT inst_id,
           sql_id,
           NVL(parsing_schema_name, 'UNKNOWN') AS schema_name,
           NVL(sharable_mem, 0) AS share_bytes,
           SUBSTR(REPLACE(REPLACE(sql_text, CHR(10), ' '), CHR(13), ' '), 1, 100) AS sql_text,
           REGEXP_REPLACE(
               REGEXP_REPLACE(
                   REGEXP_REPLACE(SUBSTR(sql_text, 1, 4000), '''[^'']*''', '''#'''),
                   '[0-9]+', '#'),
               '[[:space:]]+', ' ') AS norm_sql
      FROM gv$sqlarea
),
agg AS (
    SELECT norm_sql,
           COUNT(DISTINCT sql_id) AS sql_cnt,
           COUNT(DISTINCT inst_id) AS nodes,
           SUM(share_bytes) AS mem,
           MAX(schema_name) AS schema_name,
           MIN(sql_id) AS sql_id,
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
 WHERE r.rn <= 15
 ORDER BY r.rn;

PROMPT
PROMPT Done.
PROMPT
