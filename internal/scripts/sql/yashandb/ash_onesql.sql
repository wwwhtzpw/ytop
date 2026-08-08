-- File Name: ash_onesql.sql
-- Purpose: YashanDB ASH detail and wait-class summary for one SQL_ID (GV$ASH)
-- Created: 20260613  by  huangtingzhong
-- Oracle ref: ash_onesql.sql
-- Variables: &btime (yyyy-mm-dd hh24:mi:ss), &hour (interval hours), &sql_id
-- Numeric/time &vars: empty => default via NVL/TO_NUMBER (safe for ytop and yasql).

col time          for a19
col inst          for a3
col sess_id       for a16
col session_state for a10
col oprogram      for a20
col sqlid         for a13
col oevent        for a25
col wait_class    for a15

SELECT TO_CHAR(sample_time, 'yyyy-mm-dd hh24:mi:ss') AS time,
       TO_CHAR(inst_id) AS inst,
       inst_id || '-' || session_id || '-' || session_serial# AS sess_id,
       session_state,
       SUBSTR(program, 1, 20) AS oprogram,
       sql_id AS sqlid,
       SUBSTR(NVL(event, session_state), 1, 25) AS oevent,
       wait_class
  FROM gv$active_session_history
 WHERE is_awr_sample = 'N'
   AND sample_time >= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
   AND sample_time <= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24) + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
   AND sql_id = '&sql_id'
UNION ALL
SELECT TO_CHAR(sample_time, 'yyyy-mm-dd hh24:mi:ss') AS time,
       TO_CHAR(instance_number) AS inst,
       instance_number || '-' || session_id || '-' || session_serial#,
       session_state,
       SUBSTR(program, 1, 20),
       sql_id,
       SUBSTR(NVL(event, session_state), 1, 25),
       wait_class
  FROM dba_hist_active_sess_history
 WHERE sample_time >= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
   AND sample_time <= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24) + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
   AND sql_id = '&sql_id'
 ORDER BY time;

col total  for a8
col opcode for a8

SELECT sql_id,
       TO_CHAR(SUM(cnt)) AS total,
       SUM(DECODE(wait_class, 'Other', cnt, 0)) AS other,
       SUM(DECODE(wait_class, 'Network', cnt, 0)) AS net,
       SUM(DECODE(wait_class, 'Application', cnt, 0)) AS app,
       SUM(DECODE(wait_class, 'Administration', cnt, 0)) AS admin,
       SUM(DECODE(wait_class, 'Cluster', cnt, 0)) AS clust,
       SUM(DECODE(wait_class, 'Concurrency', cnt, 0)) AS concur,
       SUM(DECODE(wait_class, 'Configuration', cnt, 0)) AS config,
       SUM(DECODE(wait_class, 'Commit', cnt, 0)) AS commit,
       SUM(DECODE(wait_class, 'System I/O', cnt, 0)) AS s_io,
       SUM(DECODE(wait_class, 'User I/O', cnt, 0)) AS uio,
       SUM(DECODE(wait_class, 'ON CPU', cnt, 0)) AS cpu,
       SUM(DECODE(wait_class, 'BCPU', cnt, 0)) AS bcpu,
       SUBSTR(DECODE(MAX(sql_opcode),
                       1, 'DDL',
                       2, 'INSERT',
                       3, 'Query',
                       6, 'UPDATE',
                       7, 'DELETE',
                       47, 'PL/SQL',
                       50, 'Explain',
                       170, 'CALL',
                       189, 'MERGE',
                       TO_CHAR(MAX(sql_opcode))), 1, 8) AS opcode,
       sql_plan_hash_value
  FROM (
        SELECT sql_id,
               sample_id,
               DECODE(NVL(sql_id, '0'), '0', 0, sql_opcode) AS sql_opcode,
               DECODE(session_state,
                      'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'ON CPU'),
                      NVL(wait_class, 'Other')) AS wait_class,
               1 AS cnt,
               sql_plan_hash_value
          FROM gv$active_session_history
         WHERE is_awr_sample = 'N'
           AND sample_time >= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
           AND sample_time <= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24) + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
           AND sql_id = '&sql_id'
        UNION ALL
        SELECT sql_id,
               sample_id,
               DECODE(NVL(sql_id, '0'), '0', 0, sql_opcode) AS sql_opcode,
               DECODE(session_state,
                      'ON CPU', DECODE(session_type, 'BACKGROUND', 'BCPU', 'ON CPU'),
                      NVL(wait_class, 'Other')) AS wait_class,
               10 AS cnt,
               sql_plan_hash_value
          FROM dba_hist_active_sess_history
         WHERE sample_time >= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24)
           AND sample_time <= NVL(TO_DATE(NULLIF(TRIM('&btime'), ''), 'yyyy-mm-dd hh24:mi:ss'), SYSDATE - NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24) + NVL(TO_NUMBER(NULLIF(TRIM('&hour'), '')), 1) / 24
           AND sql_id = '&sql_id'
       ) ash
 GROUP BY sql_id, sql_plan_hash_value
 ORDER BY cpu DESC;
