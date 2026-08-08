-- File Name: ash.sql
-- Purpose: YashanDB ASH wait class matrix by time bucket (GV$ASH)
-- Created: 20260613  by  huangtingzhong
-- Oracle ref: ash_total.sql
-- Variables (empty => default):
--   &display_time  bucket minutes (default 1)
--   &btime         yyyy-mm-dd hh24:mi:ss (default SYSDATE - &hour)
--   &hour          interval hours (default 1)
-- Numeric &vars use quoted NVL/TO_NUMBER so empty input is safe for ytop and yasql.

col time    for a18
col total   for a8
col other   for a8
col net     for a8
col app     for a8
col admin   for a8
col clust   for a8
col concur  for a8
col config  for a8
col commit  for a8
col sio     for a8
col uio     for a8
col cpu     for a8
col bcpu    for a8

SELECT TO_CHAR(date_hh, 'yyyymmdd hh24') || ' '
       || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * date_mi || '-'
       || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * (date_mi + 1) AS time,
       TO_CHAR(SUM(cnt)) AS total,
       TO_CHAR(SUM(DECODE(wait_class, 'Other', cnt, 0))) AS other,
       TO_CHAR(SUM(DECODE(wait_class, 'Network', cnt, 0))) AS net,
       TO_CHAR(SUM(DECODE(wait_class, 'Application', cnt, 0))) AS app,
       TO_CHAR(SUM(DECODE(wait_class, 'Administration', cnt, 0))) AS admin,
       TO_CHAR(SUM(DECODE(wait_class, 'Cluster', cnt, 0))) AS clust,
       TO_CHAR(SUM(DECODE(wait_class, 'Concurrency', cnt, 0))) AS concur,
       TO_CHAR(SUM(DECODE(wait_class, 'Configuration', cnt, 0))) AS config,
       TO_CHAR(SUM(DECODE(wait_class, 'Commit', cnt, 0))) AS commit,
       TO_CHAR(SUM(DECODE(wait_class, 'System I/O', cnt, 0))) AS sio,
       TO_CHAR(SUM(DECODE(wait_class, 'User I/O', cnt, 0))) AS uio,
       TO_CHAR(SUM(DECODE(wait_class, 'ON CPU', cnt, 0))) AS cpu,
       TO_CHAR(SUM(DECODE(wait_class, 'BCPU', cnt, 0))) AS bcpu
  FROM (
        SELECT TRUNC(sample_time, 'HH') AS date_hh,
               TRUNC(TO_CHAR(sample_time, 'MI')
                     / NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1)) AS date_mi,
               DECODE(session_state,
                      'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'ON CPU'),
                      NVL(wait_class, 'Other')) AS wait_class,
               1 AS cnt
          FROM gv$active_session_history
         WHERE is_awr_sample = 'N'
           AND sample_time >= NVL(
                 TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'),
                 SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
           AND sample_time <= NVL(
                 TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'),
                 SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
               + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
        UNION ALL
        SELECT TRUNC(sample_time, 'HH') AS date_hh,
               TRUNC(TO_CHAR(sample_time, 'MI')
                     / NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1)) AS date_mi,
               DECODE(session_state,
                      'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'ON CPU'),
                      NVL(wait_class, 'Other')) AS wait_class,
               10 AS cnt
          FROM dba_hist_active_sess_history
         WHERE sample_time >= NVL(
                 TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'),
                 SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
           AND sample_time <= NVL(
                 TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'),
                 SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
               + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
       ) ash
 GROUP BY TO_CHAR(date_hh, 'yyyymmdd hh24') || ' '
          || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * date_mi || '-'
          || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * (date_mi + 1)
 ORDER BY 1;
