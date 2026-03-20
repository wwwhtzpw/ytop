-- File Name: ys_awr_event_avg_time_trend.sql
-- Purpose: AWR wait event average response time by day and hour (0-23), optional filter by event name.
-- Created: 20260206  by  huangtingzhong
-- Params: &&eventname (default empty = all non-Idle events; set to e.g. 'log file sync' for one event)

UNDEFINE eventname;

COL time_yyyymmdd FOR A8
COL event_name   FOR A30
COL h0  FOR A8
COL h1  FOR A8
COL h2  FOR A8
COL h3  FOR A8
COL h4  FOR A8
COL h5  FOR A8
COL h6  FOR A8
COL h7  FOR A8
COL h8  FOR A8
COL h9  FOR A8
COL h10 FOR A8
COL h11 FOR A8
COL h12 FOR A8
COL h13 FOR A8
COL h14 FOR A8
COL h15 FOR A8
COL h16 FOR A8
COL h17 FOR A8
COL h18 FOR A8
COL h19 FOR A8
COL h20 FOR A8
COL h21 FOR A8
COL h22 FOR A8
COL h23 FOR A8

WITH
intervals AS (
  SELECT
    a.SNAP_ID AS snap_begin,
    b.SNAP_ID AS snap_end,
    b.END_INTERVAL_TIME AS end_time,
    TO_CHAR(b.END_INTERVAL_TIME, 'YYYYMMDD') AS time_yyyymmdd,
    EXTRACT(HOUR FROM b.END_INTERVAL_TIME) AS hour_of_day
  FROM SYS.WRM$_SNAPSHOT a
  JOIN SYS.WRM$_SNAPSHOT b
    ON b.INSTANCE_NUMBER = a.INSTANCE_NUMBER AND b.SNAP_ID = a.SNAP_ID + 1
  WHERE a.INSTANCE_NUMBER = (SELECT INSTANCE_NUMBER FROM V$INSTANCE)
),
delta AS (
  SELECT
    i.time_yyyymmdd,
    i.hour_of_day,
    en.NAME AS event_name,
    (e2.TIME_WAITED_MICRO - e1.TIME_WAITED_MICRO) AS time_waited_micro_delta,
    (e2.TOTAL_WAITS - e1.TOTAL_WAITS) AS total_waits_delta
  FROM intervals i
  JOIN SYS.WRH$_SYSTEM_EVENT e1
    ON e1.SNAP_ID = i.snap_begin AND e1.INSTANCE_NUMBER = (SELECT INSTANCE_NUMBER FROM V$INSTANCE)
  JOIN SYS.WRH$_SYSTEM_EVENT e2
    ON e2.SNAP_ID = i.snap_end AND e2.INSTANCE_NUMBER = e1.INSTANCE_NUMBER AND e2.EVENT_ID = e1.EVENT_ID
  JOIN V$EVENT_NAME en ON en.EVENT_ID = e1.EVENT_ID
  WHERE en.WAIT_CLASS <> 'Idle'
    AND en.NAME = NVL(NULLIF(TRIM('&&eventname'), ''), en.NAME)
    AND (e2.TIME_WAITED_MICRO - e1.TIME_WAITED_MICRO) >= 0
    AND (e2.TOTAL_WAITS - e1.TOTAL_WAITS) > 0
),
by_hour AS (
  SELECT time_yyyymmdd, event_name, hour_of_day,
         SUM(time_waited_micro_delta) / 1000.0 / NULLIF(SUM(total_waits_delta), 0) AS avg_response_ms
  FROM delta
  GROUP BY time_yyyymmdd, event_name, hour_of_day
)
SELECT time_yyyymmdd,
  event_name,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 0  THEN avg_response_ms END), 2)) AS h0,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 1  THEN avg_response_ms END), 2)) AS h1,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 2  THEN avg_response_ms END), 2)) AS h2,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 3  THEN avg_response_ms END), 2)) AS h3,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 4  THEN avg_response_ms END), 2)) AS h4,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 5  THEN avg_response_ms END), 2)) AS h5,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 6  THEN avg_response_ms END), 2)) AS h6,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 7  THEN avg_response_ms END), 2)) AS h7,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 8  THEN avg_response_ms END), 2)) AS h8,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 9  THEN avg_response_ms END), 2)) AS h9,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 10 THEN avg_response_ms END), 2)) AS h10,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 11 THEN avg_response_ms END), 2)) AS h11,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 12 THEN avg_response_ms END), 2)) AS h12,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 13 THEN avg_response_ms END), 2)) AS h13,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 14 THEN avg_response_ms END), 2)) AS h14,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 15 THEN avg_response_ms END), 2)) AS h15,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 16 THEN avg_response_ms END), 2)) AS h16,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 17 THEN avg_response_ms END), 2)) AS h17,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 18 THEN avg_response_ms END), 2)) AS h18,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 19 THEN avg_response_ms END), 2)) AS h19,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 20 THEN avg_response_ms END), 2)) AS h20,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 21 THEN avg_response_ms END), 2)) AS h21,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 22 THEN avg_response_ms END), 2)) AS h22,
  TO_CHAR(ROUND(MAX(CASE WHEN hour_of_day = 23 THEN avg_response_ms END), 2)) AS h23
FROM by_hour
GROUP BY time_yyyymmdd, event_name
ORDER BY time_yyyymmdd, event_name;
