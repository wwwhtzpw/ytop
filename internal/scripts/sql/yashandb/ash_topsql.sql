-- File Name: ash_topsql.sql
-- Purpose: YashanDB ASH top SQL by time bucket (GV$ASH, DB%/CPU%)
-- Created: 20260613  by  huangtingzhong
-- Oracle ref: ash_topsql.sql
-- Variables: &btime (yyyy-mm-dd hh24:mi:ss), &hour (interval hours), &display_time, &top_n
-- Numeric/time &vars: empty => default via NVL/TO_NUMBER (safe for ytop and yasql).

col time     for a17
col sql_id   for a13
col rank     for a3
col db_pct   for a6
col cpu_pct  for a6
col total    for a8
col other    for a8
col net      for a6
col app      for a6
col admin    for a6
col clust    for a8
col concur   for a8
col config   for a8
col commit   for a8
col sio      for a6
col uio      for a6
col cpu      for a6
col bcpu     for a6


WITH ash_raw AS (
    SELECT sql_id,
           sample_time,
           tm_delta_db_time,
           tm_delta_time,
           tm_delta_cpu_time,
           DECODE(session_state,
                  'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'ON CPU'),
                  NVL(wait_class, 'Other')) AS wait_class,
           1 AS cnt
      FROM gv$active_session_history
     WHERE is_awr_sample = 'N'
       AND sample_time >= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
       AND sample_time <= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24) + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
    UNION ALL
    SELECT sql_id,
           sample_time,
           tm_delta_db_time,
           tm_delta_time,
           tm_delta_cpu_time,
           DECODE(session_state,
                  'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'ON CPU'),
                  NVL(wait_class, 'Other')) AS wait_class,
           10 AS cnt
      FROM dba_hist_active_sess_history
     WHERE sample_time >= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
       AND sample_time <= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24) + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
),
agg AS (
    SELECT TO_CHAR(sample_time, 'yyyymmdd hh24') || ' '
           || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * FLOOR(EXTRACT(MINUTE FROM sample_time) / NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1)) || '-'
           || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * (FLOOR(EXTRACT(MINUTE FROM sample_time) / NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1)) + 1) AS time,
           ash.sql_id,
           SUM(cnt) AS total,
           SUM(DECODE(wait_class, 'Other', cnt, 0)) AS other,
           SUM(DECODE(wait_class, 'Network', cnt, 0)) AS net,
           SUM(DECODE(wait_class, 'Application', cnt, 0)) AS app,
           SUM(DECODE(wait_class, 'Administration', cnt, 0)) AS admin,
           SUM(DECODE(wait_class, 'Cluster', cnt, 0)) AS clust,
           SUM(DECODE(wait_class, 'Concurrency', cnt, 0)) AS concur,
           SUM(DECODE(wait_class, 'Configuration', cnt, 0)) AS config,
           SUM(DECODE(wait_class, 'Commit', cnt, 0)) AS commit,
           SUM(DECODE(wait_class, 'System I/O', cnt, 0)) AS sio,
           SUM(DECODE(wait_class, 'User I/O', cnt, 0)) AS uio,
           SUM(DECODE(wait_class, 'ON CPU', cnt, 0)) AS cpu,
           SUM(DECODE(wait_class, 'BCPU', cnt, 0)) AS bcpu,
           SUM(tm_delta_db_time) AS sum_db_time,
           SUM(tm_delta_time) AS sum_elapsed,
           SUM(tm_delta_cpu_time) AS sum_cpu_time
      FROM ash_raw ash
     GROUP BY TO_CHAR(sample_time, 'yyyymmdd hh24') || ' '
              || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * FLOOR(EXTRACT(MINUTE FROM sample_time) / NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1)) || '-'
              || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * (FLOOR(EXTRACT(MINUTE FROM sample_time) / NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1)) + 1),
              ash.sql_id
)
SELECT ranked.time,
       ranked.sql_id,
       TO_CHAR(ranked.rn) AS rank,
       TO_CHAR(TRUNC(100 * ranked.sum_db_time / NULLIF(ranked.sum_elapsed, 0))) AS db_pct,
       TO_CHAR(TRUNC(100 * ranked.sum_cpu_time / NULLIF(ranked.sum_elapsed, 0))) AS cpu_pct,
       TO_CHAR(ranked.total) AS total,
       TO_CHAR(ranked.other) AS other,
       TO_CHAR(ranked.net) AS net,
       TO_CHAR(ranked.app) AS app,
       TO_CHAR(ranked.admin) AS admin,
       TO_CHAR(ranked.clust) AS clust,
       TO_CHAR(ranked.concur) AS concur,
       TO_CHAR(ranked.config) AS config,
       TO_CHAR(ranked.commit) AS commit,
       TO_CHAR(ranked.sio) AS sio,
       TO_CHAR(ranked.uio) AS uio,
       TO_CHAR(ranked.cpu) AS cpu,
       TO_CHAR(ranked.bcpu) AS bcpu
  FROM (
        SELECT agg.*,
               ROW_NUMBER() OVER (PARTITION BY agg.time ORDER BY agg.sum_db_time DESC) AS rn
          FROM agg
       ) ranked
 WHERE ranked.rn <= NVL(TO_NUMBER(NULLIF(TRIM('&top_n'), '')), 10)
 ORDER BY ranked.time, ranked.rn;
