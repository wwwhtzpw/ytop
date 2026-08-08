-- File Name: ash_topwait.sql
-- Purpose: YashanDB ASH top wait events by sample count (GV$ASH)
-- Created: 20260613  by  huangtingzhong
-- Oracle ref: ash_topwait.sql
-- Variables: &btime (yyyy-mm-dd hh24:mi:ss), &hour (interval hours)
-- Numeric/time &vars: empty => default via NVL/TO_NUMBER (safe for ytop and yasql).

col event       for a50
col wait_class  for a20
col total       for a12

SELECT event,
       wait_class,
       TO_CHAR(SUM(cnt)) AS total
  FROM (
        SELECT DECODE(session_state,
                       'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'CPU'),
                       NVL(event, NVL(session_state, 'Other'))) AS event,
               REPLACE(
                   TRANSLATE(
                       DECODE(session_state,
                              'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'CPU'),
                              NVL(wait_class, 'Other')),
                       ' $', '____'),
                   '/', '_') AS wait_class,
               1 AS cnt
          FROM gv$active_session_history
         WHERE is_awr_sample = 'N'
           AND sample_time >= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
           AND sample_time <= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24) + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
        UNION ALL
        SELECT DECODE(session_state,
                       'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'CPU'),
                       NVL(event, NVL(session_state, 'Other'))) AS event,
               REPLACE(
                   TRANSLATE(
                       DECODE(session_state,
                              'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'CPU'),
                              NVL(wait_class, 'Other')),
                       ' $', '____'),
                   '/', '_') AS wait_class,
               10 AS cnt
          FROM dba_hist_active_sess_history
         WHERE sample_time >= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
           AND sample_time <= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24) + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
       )
 GROUP BY event, wait_class
 ORDER BY SUM(cnt) DESC;
