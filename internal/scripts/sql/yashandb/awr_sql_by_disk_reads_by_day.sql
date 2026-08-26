-- File Name: awr_sql_by_disk_reads_by_day.sql
-- Purpose: YashanDB AWR top SQL by disk reads per day
-- Created: 20250307  by  huangtingzhong

-- Updated: 20260809 by huangtingzhong (username/exclude_user; shorter display col aliases)
-- Params:
--   days_back    : earliest N days window (Enter=2)
--   days_show    : show last M days within window (Enter=2)
--   username     : include schema(s), comma-separated (Enter=no filter)
--   exclude_user : exclude schema(s), comma-separated (Enter=no exclude)
COL day       FOR A11
COL rn        FOR A3
COL gets      FOR A14
COL execs     FOR A10
COL avg_gets  FOR A10
COL gets_pct  FOR A8
COL ela_s     FOR A10
COL cpu_pct   FOR A7
COL io_pct    FOR A7
COL sql_id    FOR A13
COL module    FOR A20
COL text      FOR A40

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | AWR top SQL by day                                                     |
PROMPT | days_back/days_show : Enter = 2                                        |
PROMPT | username / exclude_user : Enter = none; CSV schemas ok                 |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT days_back PROMPT 'Enter days_back (Enter=2): '
ACCEPT days_show PROMPT 'Enter days_show (Enter=2): '
ACCEPT username PROMPT 'Enter username/schema(s) (Enter=no filter, CSV ok): '
ACCEPT exclude_user PROMPT 'Enter exclude_user(s) (Enter=no exclude, CSV ok): '

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
    WHERE (NULLIF(TRIM('&&username'), '') IS NULL
           OR INSTR(',' || UPPER(REPLACE(TRIM('&&username'), ' ', '')) || ',',
                    ',' || UPPER(TRIM(d.parsing_schema_name)) || ',') > 0)
      AND (NULLIF(TRIM('&&exclude_user'), '') IS NULL
           OR INSTR(',' || UPPER(REPLACE(TRIM('&&exclude_user'), ' ', '')) || ',',
                    ',' || UPPER(TRIM(d.parsing_schema_name)) || ',') = 0)
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
           ROW_NUMBER() OVER (PARTITION BY p.snap_day ORDER BY p.dreads DESC NULLS LAST, p.SQL_ID, p.module) AS rn
    FROM per_day_agg p
    JOIN totals t ON t.snap_day = p.snap_day
    WHERE NVL(p.dreads, 0) > 0
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
SELECT t.snap_day AS day,
       TO_CHAR(ROW_NUMBER() OVER (PARTITION BY t.snap_day ORDER BY t.dreads DESC NULLS LAST, t.SQL_ID, t.module)) AS rn,
       TO_CHAR(t.bget) AS gets,
       TO_CHAR(t.exec) AS execs,
       TO_CHAR(ROUND(DECODE(t.exec, 0, NULL, t.bget / t.exec), 2)) AS avg_gets,
       TO_CHAR(ROUND(t.norm_val, 2)) AS gets_pct,
       TO_CHAR(ROUND(NVL(t.elap / 1000000, NULL), 2)) AS ela_s,
       TO_CHAR(ROUND(DECODE(t.elap, 0, NULL, 100 * t.cput / t.elap), 2)) AS cpu_pct,
       TO_CHAR(ROUND(DECODE(t.elap, 0, NULL, 100 * t.uiot / t.elap), 2)) AS io_pct,
       t.SQL_ID     AS sql_id,
       t.module     AS module,
       t.sql_text AS text
FROM top10 t
ORDER BY t.snap_day DESC, t.dreads DESC NULLS LAST, t.SQL_ID, t.module
/
