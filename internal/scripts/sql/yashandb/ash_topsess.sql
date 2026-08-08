-- File Name: ash_topsess.sql
-- Purpose: YashanDB ASH top sessions by time bucket (GV$ASH, cluster)
-- Created: 20260613  by  huangtingzhong
-- Oracle ref: ash_topsess.sql
-- Variables: &btime (yyyy-mm-dd hh24:mi:ss), &hour (interval hours), &display_time, &top_n
-- Numeric/time &vars: empty => default via NVL/TO_NUMBER (safe for ytop and yasql).

col time     for a17
col sid      for a16
col rank     for a3
col db_pct   for a6
col cpu_pct  for a6
col tdb_pct  for a8
col total    for a8
col cpu      for a6
col bcpu     for a6
col uio      for a6
col username for a12
col program  for a20



WITH ash_raw AS (
    SELECT inst_id,
           session_id,
           session_serial#,
           user_id,
           program,
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
    SELECT instance_number AS inst_id,
           session_id,
           session_serial#,
           user_id,
           program,
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
           ash.inst_id,
           ash.session_id,
           ash.session_serial#,
           NVL(u.username, ash.inst_id || '.' || ash.session_id || '.' || ash.session_serial#) AS username,
           ash.program,
           SUM(cnt) AS total,
           SUM(DECODE(wait_class, 'ON CPU', cnt, 0)) AS cpu,
           SUM(DECODE(wait_class, 'BCPU', cnt, 0)) AS bcpu,
           SUM(DECODE(wait_class, 'User I/O', cnt, 0)) AS uio,
           SUM(tm_delta_db_time) AS sum_db_time,
           SUM(tm_delta_time) AS sum_elapsed,
           SUM(tm_delta_cpu_time) AS sum_cpu_time
      FROM ash_raw ash
      LEFT JOIN dba_users u ON ash.user_id = u.user_id
     GROUP BY TO_CHAR(sample_time, 'yyyymmdd hh24') || ' '
              || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * FLOOR(EXTRACT(MINUTE FROM sample_time) / NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1)) || '-'
              || NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1) * (FLOOR(EXTRACT(MINUTE FROM sample_time) / NVL(TO_NUMBER(NULLIF(TRIM('&display_time'), '')), 1)) + 1),
              ash.inst_id,
              ash.session_id,
              ash.session_serial#,
              NVL(u.username, ash.inst_id || '.' || ash.session_id || '.' || ash.session_serial#),
              ash.program
)
SELECT ranked.time,
       ranked.inst_id || ',' || ranked.session_id || ',' || ranked.session_serial# AS sid,
       TO_CHAR(ranked.rn) AS rank,
       TO_CHAR(TRUNC(100 * ranked.sum_db_time / NULLIF(ranked.sum_elapsed, 0))) AS db_pct,
       TO_CHAR(TRUNC(100 * ranked.sum_cpu_time / NULLIF(ranked.sum_elapsed, 0))) AS cpu_pct,
       TO_CHAR(ROUND(100 * ranked.sum_db_time / NULLIF(ranked.total_db_time, 0), 2)) AS tdb_pct,
       TO_CHAR(ranked.total) AS total,
       TO_CHAR(ranked.cpu) AS cpu,
       TO_CHAR(ranked.bcpu) AS bcpu,
       TO_CHAR(ranked.uio) AS uio,
       SUBSTR(ranked.username, 1, 12) AS username,
       SUBSTR(ranked.program, 1, 20) AS program
  FROM (
        SELECT agg.*,
               ROW_NUMBER() OVER (PARTITION BY agg.time ORDER BY NVL(agg.sum_db_time, 0) DESC) AS rn,
               SUM(agg.sum_db_time) OVER (PARTITION BY agg.time) AS total_db_time
          FROM agg
       ) ranked
 WHERE ranked.rn <= NVL(TO_NUMBER(NULLIF(TRIM('&top_n'), '')), 10)
 ORDER BY ranked.time, ranked.rn;
