-- File Name: awr_top10_sql_by_cpu_yashan.sql
-- Purpose: AWR TOP 10 SQL by CPU per day (deduped by day) from WRH$/WRM$ views.
-- Created: 20250307  by  yashandb_rewrite
-- Params: &&days_back = earliest N days (default 2), &&days_show = collect M days (default 2, show last M days)
SET LINES 200
SET PAGES 500
COL snap_day     FOR A12
COL rn           FOR A4
COL sql_bget     FOR A18
COL sql_exec     FOR A14
COL sql_per_get  FOR A16
COL sql_norm_val FOR A10
COL sql_elap     FOR A14
COL sql_cpu      FOR A8
COL sql_io       FOR A8
COL sql_id       FOR A16
COL sql_module   FOR A24
COL sql_text     FOR A40
UNDEFINE days_back
UNDEFINE days_show

WITH
snap_days_range AS (
    SELECT TRUNC(s.BEGIN_INTERVAL_TIME) AS snap_day,
           MIN(s.SNAP_ID) AS bid,
           MAX(s.SNAP_ID) AS eid,
           MAX(s.DBID) AS DBID,
           MAX(s.INSTANCE_NUMBER) AS INSTANCE_NUMBER
    FROM SYS.WRM$_SNAPSHOT s
    WHERE s.INSTANCE_NUMBER = (SELECT instance_number FROM v$instance)
      AND TRUNC(s.BEGIN_INTERVAL_TIME) >= TRUNC(SYSDATE) - NVL(TO_NUMBER(NULLIF(TRIM('&&days_back'), '')), 2)
    GROUP BY TRUNC(s.BEGIN_INTERVAL_TIME)
),
snap_days AS (
    SELECT snap_day, bid, eid, DBID, INSTANCE_NUMBER
    FROM (
        SELECT s.*, ROW_NUMBER() OVER (ORDER BY s.snap_day DESC) AS rk
        FROM snap_days_range s
    )
    WHERE rk <= NVL(TO_NUMBER(NULLIF(TRIM('&&days_show'), '')), 2)
),
per_day_agg AS (
    SELECT sd.snap_day,
           d.SQL_ID,
           SUBSTR(d.MODULE, 1, 20) AS module,
           SUM(d.CPU_TIME_DELTA)     AS cput,
           SUM(d.ELAPSED_TIME_DELTA) AS elap,
           SUM(d.EXECUTIONS_DELTA)   AS exec,
           SUM(d.IOWAIT_DELTA)       AS uiot,
           SUM(d.BUFFER_GETS_DELTA)  AS bget,
           SUM(d.DISK_READS_DELTA)  AS dreads
    FROM SYS.WRH$_SQLSTAT d
    JOIN snap_days sd
      ON d.SNAP_ID > sd.bid AND d.SNAP_ID <= sd.eid
     AND d.DBID = sd.DBID
     AND d.INSTANCE_NUMBER = sd.INSTANCE_NUMBER
    GROUP BY sd.snap_day, d.SQL_ID, SUBSTR(d.MODULE, 1, 20)
),
totals AS (
    SELECT snap_day,
           NVL(SUM(bget), 0) AS total_bget
    FROM per_day_agg
    GROUP BY snap_day
),
ranked AS (
    SELECT p.snap_day,
           p.SQL_ID,
           p.module,
           p.cput,
           p.elap,
           p.exec,
           p.uiot,
           p.bget,
           p.dreads,
           ROUND(100 * p.bget / NULLIF(t.total_bget, 0), 2) AS norm_val,
           ROW_NUMBER() OVER (PARTITION BY p.snap_day ORDER BY p.cput DESC NULLS LAST, p.SQL_ID, p.module) AS rn
    FROM per_day_agg p
    JOIN totals t ON t.snap_day = p.snap_day
    WHERE NVL(p.cput, 0) > 0 OR NVL(p.bget, 0) > 0
),
top10 AS (
    SELECT r.snap_day, r.SQL_ID, r.module, r.cput, r.elap, r.exec, r.uiot, r.bget, r.dreads, r.norm_val,
           NVL(SUBSTR(st.SQL_TEXT, 1, 40), '** SQL Text Not Available **') AS sql_text
    FROM ranked r
    LEFT JOIN (
        SELECT SQL_ID, SUBSTR(SQL_TEXT, 1, 40) AS SQL_TEXT,
               ROW_NUMBER() OVER (PARTITION BY SQL_ID ORDER BY SNAP_ID DESC) AS rk
        FROM SYS.WRH$_SQLTEXT
    ) st ON st.SQL_ID = r.SQL_ID AND st.rk = 1
    WHERE r.rn <= 10
)
SELECT t.snap_day,
       TO_CHAR(ROW_NUMBER() OVER (PARTITION BY t.snap_day ORDER BY t.cput DESC NULLS LAST, t.SQL_ID, t.module)) AS rn,
       TO_CHAR(t.bget) AS sql_bget,
       TO_CHAR(t.exec) AS sql_exec,
       TO_CHAR(ROUND(DECODE(t.exec, 0, NULL, t.bget / t.exec), 2)) AS sql_per_get,
       TO_CHAR(ROUND(t.norm_val, 2)) AS sql_norm_val,
       TO_CHAR(ROUND(NVL(t.elap / 1000000, NULL), 2)) AS sql_elap,
       TO_CHAR(ROUND(DECODE(t.elap, 0, NULL, 100 * t.cput / t.elap), 2)) AS sql_cpu,
       TO_CHAR(ROUND(DECODE(t.elap, 0, NULL, 100 * t.uiot / t.elap), 2)) AS sql_io,
       t.SQL_ID     AS sql_id,
       t.module     AS sql_module,
       t.sql_text
FROM top10 t
ORDER BY t.snap_day DESC, t.cput DESC NULLS LAST, t.SQL_ID, t.module
/
