-- YashanDB: AWR EVENT TOP5（等价于 Oracle awr_event_top5.sql）
-- 对象映射: DBA_HIST_SNAPSHOT -> SYS.WRM$_SNAPSHOT, DBA_HIST_SYSTEM_EVENT -> SYS.WRH$_SYSTEM_EVENT + V$SYSTEM_EVENT(EVENT名/WAIT_CLASS)

col  SNAP_TIME        for a9
col  EVENT1           for a25
col  EVENT2           for a25
col  EVENT3           for a25
col  EVENT4           for a25
col  EVENT5           for a25
col  aas1             for a5
col  RATIO1           for a5
col  AVG_TIME1        for a5
col  aas2             for a5
col  RATIO2           for a5
col  AVG_TIME2        for a5
col  aas3             for a5
col  RATIO3           for a5
col  AVG_TIME3        for a5
col  aas4             for a5
col  RATIO4           for a5
col  AVG_TIME4        for a5

WITH
delta_base AS (
  SELECT
    SA.END_INTERVAL_TIME AS SNAP_TIME,
    SB.END_INTERVAL_TIME AS NEXT_SNAP_TIME,
    V.EVENT,
    (BB.TIME_WAITED_MICRO - AA.TIME_WAITED_MICRO) / 1000000.0 AS TIME_WAITED,
    (BB.TOTAL_WAITS - AA.TOTAL_WAITS) AS TOTAL_WAITS,
    EXTRACT(DAY FROM (SB.END_INTERVAL_TIME - SA.END_INTERVAL_TIME)) * 86400
      + EXTRACT(HOUR FROM (SB.END_INTERVAL_TIME - SA.END_INTERVAL_TIME)) * 3600
      + EXTRACT(MINUTE FROM (SB.END_INTERVAL_TIME - SA.END_INTERVAL_TIME)) * 60
      + EXTRACT(SECOND FROM (SB.END_INTERVAL_TIME - SA.END_INTERVAL_TIME)) AS interval_sec
  FROM SYS.WRH$_SYSTEM_EVENT AA
  JOIN SYS.WRM$_SNAPSHOT SA ON AA.SNAP_ID = SA.SNAP_ID AND AA.INSTANCE_NUMBER = SA.INSTANCE_NUMBER
  JOIN SYS.WRH$_SYSTEM_EVENT BB ON AA.EVENT_ID = BB.EVENT_ID AND AA.INSTANCE_NUMBER = BB.INSTANCE_NUMBER AND BB.SNAP_ID = AA.SNAP_ID + 1
  JOIN SYS.WRM$_SNAPSHOT SB ON BB.SNAP_ID = SB.SNAP_ID AND BB.INSTANCE_NUMBER = SB.INSTANCE_NUMBER
  JOIN V$SYSTEM_EVENT V ON AA.EVENT_ID = V.EVENT_ID
  WHERE AA.INSTANCE_NUMBER = (SELECT INSTANCE_NUMBER FROM V$INSTANCE)
    AND V.WAIT_CLASS <> 'Idle'
),
with_total AS (
  SELECT SNAP_TIME, NEXT_SNAP_TIME, EVENT, TIME_WAITED, TOTAL_WAITS, interval_sec,
         SUM(TIME_WAITED) OVER (PARTITION BY SNAP_TIME) AS total_time_waited,
         ROW_NUMBER() OVER (PARTITION BY SNAP_TIME ORDER BY TIME_WAITED DESC) AS RN
  FROM delta_base
  WHERE interval_sec > 0
),
top5 AS (
  SELECT
    TO_CHAR(SNAP_TIME, 'mmdd hh24:mi') AS snap_time,
    TO_CHAR(NEXT_SNAP_TIME, 'mmdd hh24:mi') AS next_snap_time,
    EVENT,
    TIME_WAITED,
    ROUND(TIME_WAITED / NULLIF(interval_sec, 0), 2) AS AAS,
    ROUND(TIME_WAITED * 100 / NULLIF(total_time_waited, 0), 2) AS RATIO,
    CASE
      WHEN TOTAL_WAITS = 0 OR TOTAL_WAITS IS NULL THEN NULL
      WHEN (TIME_WAITED * 1000 / TOTAL_WAITS) < 1000 THEN TO_CHAR(ROUND(TIME_WAITED * 1000 / TOTAL_WAITS, 0))
      WHEN (TIME_WAITED * 1000 / TOTAL_WAITS) BETWEEN 1000 AND 1000000 THEN ROUND(TIME_WAITED * 1000 / TOTAL_WAITS / 1000, 1) || 'S'
      ELSE ROUND(TIME_WAITED * 1000 / TOTAL_WAITS / 1000 / 60, 0) || 'M'
    END AS avg_time,
    RN
  FROM with_total
  WHERE RN <= 5
),
pivot_top5 AS (
  SELECT snap_time, next_snap_time, RN,
    EVENT AS event1,
    AAS AS aas1,
    RATIO AS ratio1,
    avg_time AS avg_time1,
    LEAD(EVENT, 1) OVER (PARTITION BY snap_time ORDER BY RN) AS event2,
    LEAD(AAS, 1) OVER (PARTITION BY snap_time ORDER BY RN) AS aas2,
    LEAD(RATIO, 1) OVER (PARTITION BY snap_time ORDER BY RN) AS ratio2,
    LEAD(avg_time, 1) OVER (PARTITION BY snap_time ORDER BY RN) AS avg_time2,
    LEAD(EVENT, 2) OVER (PARTITION BY snap_time ORDER BY RN) AS event3,
    LEAD(AAS, 2) OVER (PARTITION BY snap_time ORDER BY RN) AS aas3,
    LEAD(RATIO, 2) OVER (PARTITION BY snap_time ORDER BY RN) AS ratio3,
    LEAD(avg_time, 2) OVER (PARTITION BY snap_time ORDER BY RN) AS avg_time3,
    LEAD(EVENT, 3) OVER (PARTITION BY snap_time ORDER BY RN) AS event4,
    LEAD(AAS, 3) OVER (PARTITION BY snap_time ORDER BY RN) AS aas4,
    LEAD(RATIO, 3) OVER (PARTITION BY snap_time ORDER BY RN) AS ratio4,
    LEAD(avg_time, 3) OVER (PARTITION BY snap_time ORDER BY RN) AS avg_time4,
    LEAD(EVENT, 4) OVER (PARTITION BY snap_time ORDER BY RN) AS event5,
    LEAD(AAS, 4) OVER (PARTITION BY snap_time ORDER BY RN) AS aas5,
    LEAD(RATIO, 4) OVER (PARTITION BY snap_time ORDER BY RN) AS ratio5,
    LEAD(avg_time, 4) OVER (PARTITION BY snap_time ORDER BY RN) AS avg_time5
  FROM top5
)
SELECT snap_time,
  SUBSTR(event1, 1, 25) AS event1, aas1||'' aas1, ratio1||'' ratio1, avg_time1||'' avg_time1,
  SUBSTR(event2, 1, 25) AS event2, aas2||'' aas2, ratio2||'' ratio2, avg_time2||'' avg_time2,
  SUBSTR(event3, 1, 20) AS event3, aas3||'' aas3, ratio3||'' ratio3, avg_time3||'' avg_time3,
  SUBSTR(event4, 1, 15) AS event4, aas4||'' aas4, ratio4||'' ratio4, avg_time4||'' avg_time4
FROM pivot_top5
WHERE RN = 1
ORDER BY snap_time
;
