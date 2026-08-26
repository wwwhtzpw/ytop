-- File Name: awr_event_hour_trend.sql
-- Purpose: YashanDB AWR wait event hourly trend (AM/PM rows, 00-23 headers, line <= ~300 chars)
-- Created: 20260615
--
-- Params (yasql interactive or DEFINE before run):
--   &&eventname   optional; LIKE prefix match, e.g. 'log file sync', 'db file%'; empty = all non-Idle
--   &&inst_scope  optional; empty/current = connected instance; all = aggregate all instances (YAC)
--
-- Output: date | event_name | 00..23 (24-hour headers)
--   two rows per day+event: first 00-11, second 12-23; cell avg(4)｜pct(4 int%)
--   avg adaptive ms/xS/xM
--
-- Examples:
--   ytop -t <IP> -f awr_event_hour_trend.sql
--   DEFINE eventname = 'db file%'; DEFINE inst_scope = all; @awr_event_hour_trend.sql


COL "date" FOR A8
COL event_name    FOR A18
COL "00" FOR A10
COL "01" FOR A10
COL "02" FOR A10
COL "03" FOR A10
COL "04" FOR A10
COL "05" FOR A10
COL "06" FOR A10
COL "07" FOR A10
COL "08" FOR A10
COL "09" FOR A10
COL "10" FOR A10
COL "11" FOR A10
COL "12" FOR A10
COL "13" FOR A10
COL "14" FOR A10
COL "15" FOR A10
COL "16" FOR A10
COL "17" FOR A10
COL "18" FOR A10
COL "19" FOR A10
COL "20" FOR A10
COL "21" FOR A10
COL "22" FOR A10
COL "23" FOR A10

WITH
scope AS (
  SELECT CASE
           WHEN UPPER(TRIM('&&inst_scope')) = 'ALL' THEN 'ALL'
           ELSE 'CURRENT'
         END AS mode
    FROM DUAL
),
intervals AS (
  SELECT
    a.INSTANCE_NUMBER,
    a.SNAP_ID AS snap_begin,
    b.SNAP_ID AS snap_end,
    TO_CHAR(b.END_INTERVAL_TIME, 'YYYYMMDD') AS time_yyyymmdd,
    EXTRACT(HOUR FROM b.END_INTERVAL_TIME) AS hour_of_day
  FROM SYS.WRM$_SNAPSHOT a
  JOIN SYS.WRM$_SNAPSHOT b
    ON b.INSTANCE_NUMBER = a.INSTANCE_NUMBER
   AND b.SNAP_ID = a.SNAP_ID + 1
 CROSS JOIN scope s
  WHERE (s.mode = 'ALL'
         OR a.INSTANCE_NUMBER = (SELECT INSTANCE_NUMBER FROM V$INSTANCE))
),
delta_all AS (
  SELECT
    i.time_yyyymmdd,
    i.hour_of_day,
    en.NAME AS event_name,
    (e2.TIME_WAITED_MICRO - e1.TIME_WAITED_MICRO) AS time_waited_micro_delta,
    (e2.TOTAL_WAITS - e1.TOTAL_WAITS) AS total_waits_delta
  FROM intervals i
  JOIN SYS.WRH$_SYSTEM_EVENT e1
    ON e1.SNAP_ID = i.snap_begin
   AND e1.INSTANCE_NUMBER = i.INSTANCE_NUMBER
  JOIN SYS.WRH$_SYSTEM_EVENT e2
    ON e2.SNAP_ID = i.snap_end
   AND e2.INSTANCE_NUMBER = e1.INSTANCE_NUMBER
   AND e2.EVENT_ID = e1.EVENT_ID
  JOIN V$EVENT_NAME en
    ON en.EVENT_ID = e1.EVENT_ID
  WHERE en.WAIT_CLASS <> 'Idle'
    AND (e2.TIME_WAITED_MICRO - e1.TIME_WAITED_MICRO) >= 0
    AND (e2.TOTAL_WAITS - e1.TOTAL_WAITS) >= 0
),
hour_total AS (
  SELECT
    time_yyyymmdd,
    hour_of_day,
    SUM(time_waited_micro_delta) AS total_time_micro
  FROM delta_all
  GROUP BY time_yyyymmdd, hour_of_day
),
delta AS (
  SELECT d.*
  FROM delta_all d
  WHERE (NULLIF(TRIM('&&eventname'), '') IS NULL
         OR d.event_name LIKE TRIM('&&eventname'))
    AND d.total_waits_delta > 0
),
by_hour AS (
  SELECT
    d.time_yyyymmdd,
    d.event_name,
    d.hour_of_day,
    SUM(d.time_waited_micro_delta) / 1000.0 / NULLIF(SUM(d.total_waits_delta), 0) AS avg_response_ms,
    SUM(d.time_waited_micro_delta) AS event_time_micro
  FROM delta d
  GROUP BY d.time_yyyymmdd, d.event_name, d.hour_of_day
),
by_hour_pct AS (
  SELECT
    b.time_yyyymmdd,
    b.event_name,
    b.hour_of_day,
    b.avg_response_ms,
    ROUND(b.event_time_micro * 100.0 / NULLIF(t.total_time_micro, 0), 0) AS wait_pct
  FROM by_hour b
  JOIN hour_total t
    ON t.time_yyyymmdd = b.time_yyyymmdd
   AND t.hour_of_day = b.hour_of_day
),
fmt AS (
  SELECT
    time_yyyymmdd,
    event_name,
    hour_of_day,
    CASE WHEN hour_of_day < 12 THEN 'AM' ELSE 'PM' END AS seg,
    LPAD(
      CASE
        WHEN avg_response_ms IS NULL THEN ' '
        WHEN avg_response_ms < 1000 THEN TO_CHAR(ROUND(avg_response_ms, 0))
        WHEN avg_response_ms < 1000000 THEN TO_CHAR(ROUND(avg_response_ms / 1000, 1)) || 'S'
        ELSE TO_CHAR(ROUND(avg_response_ms / 60000, 0)) || 'M'
      END,
      4)
      || '｜'
      || LPAD(
           CASE
             WHEN wait_pct IS NULL THEN ' '
             ELSE TO_CHAR(LEAST(wait_pct, 100)) || '%'
           END,
           4) AS cell
  FROM by_hour_pct
)
SELECT
  time_yyyymmdd AS "date",
  event_name,
  MAX(CASE WHEN hour_of_day = 0  THEN cell END) AS "00",
  MAX(CASE WHEN hour_of_day = 1  THEN cell END) AS "01",
  MAX(CASE WHEN hour_of_day = 2  THEN cell END) AS "02",
  MAX(CASE WHEN hour_of_day = 3  THEN cell END) AS "03",
  MAX(CASE WHEN hour_of_day = 4  THEN cell END) AS "04",
  MAX(CASE WHEN hour_of_day = 5  THEN cell END) AS "05",
  MAX(CASE WHEN hour_of_day = 6  THEN cell END) AS "06",
  MAX(CASE WHEN hour_of_day = 7  THEN cell END) AS "07",
  MAX(CASE WHEN hour_of_day = 8  THEN cell END) AS "08",
  MAX(CASE WHEN hour_of_day = 9  THEN cell END) AS "09",
  MAX(CASE WHEN hour_of_day = 10 THEN cell END) AS "10",
  MAX(CASE WHEN hour_of_day = 11 THEN cell END) AS "11",
  MAX(CASE WHEN hour_of_day = 12 THEN cell END) AS "12",
  MAX(CASE WHEN hour_of_day = 13 THEN cell END) AS "13",
  MAX(CASE WHEN hour_of_day = 14 THEN cell END) AS "14",
  MAX(CASE WHEN hour_of_day = 15 THEN cell END) AS "15",
  MAX(CASE WHEN hour_of_day = 16 THEN cell END) AS "16",
  MAX(CASE WHEN hour_of_day = 17 THEN cell END) AS "17",
  MAX(CASE WHEN hour_of_day = 18 THEN cell END) AS "18",
  MAX(CASE WHEN hour_of_day = 19 THEN cell END) AS "19",
  MAX(CASE WHEN hour_of_day = 20 THEN cell END) AS "20",
  MAX(CASE WHEN hour_of_day = 21 THEN cell END) AS "21",
  MAX(CASE WHEN hour_of_day = 22 THEN cell END) AS "22",
  MAX(CASE WHEN hour_of_day = 23 THEN cell END) AS "23"
FROM fmt
GROUP BY time_yyyymmdd, event_name, seg
ORDER BY time_yyyymmdd, event_name, seg;
