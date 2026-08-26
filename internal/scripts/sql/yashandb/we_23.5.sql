-- File Name: we_23.5.sql
-- Purpose: YashanDB Session overview for YashanDB 23.5+
-- Supported: 23.5
-- Created: 20260516  by  huangtingzhong
--
-- Notes:
--   Same job-session enrichment as we.sql (LEFT JOIN process + RUNNING jobs fallback).

col SID_TID           for a20
col PROGRAM           for a30
col EVENT             for a30
col USERNAME          for a15
col SQL_ID            for a18
col EXECT             for a6
col CLIENT            for a20

SELECT 
    sid_tid,
    event,
    username,
    sql_id,
    CASE 
        WHEN exec_ms IS NULL THEN 
            'N/A'
        WHEN exec_ms < 1000 THEN 
            ROUND(exec_ms, 0) || 'MS'
        WHEN exec_ms < 60000 THEN 
            ROUND(exec_ms / 1000, 2) || 'S'
        WHEN exec_ms < 3600000 THEN 
            ROUND(exec_ms / 60000, 2) || 'M'
        WHEN exec_ms < 86400000 THEN 
            ROUND(exec_ms / 3600000, 2) || 'H'
        ELSE 
            ROUND(exec_ms / 86400000, 2) || 'D'
    END AS exect,
    program,
    client 
FROM (
    SELECT 
        x.sid_tid,
        x.event,
        x.username,
        x.program,
        x.sql_id,
        GREATEST(0,
            EXTRACT(DAY FROM x.exec_delta) * 86400000 +
            EXTRACT(HOUR FROM x.exec_delta) * 3600000 +
            EXTRACT(MINUTE FROM x.exec_delta) * 60000 +
            EXTRACT(SECOND FROM x.exec_delta) * 1000
        ) AS exec_ms,
        x.client
    FROM (
        SELECT 
            a.inst_id||'.'||a.sid||'.'||a.serial#||'.'
              ||NVL(TO_CHAR(NVL(b.thread_id, schd.thread_id)), '-') AS sid_tid,
            substr(a.wait_event,1,30) AS event,
            a.username AS username,
            substr(NVL(a.cli_program, NVL(j.job_name, a.module)),1,30) AS program,
            substr(c.command_name,1,3)||'.'||nvl(a.sql_id,a.PREV_SQL_ID) AS sql_id,
            CASE
                WHEN a.exec_start_time IS NOT NULL THEN
                    CAST(
                        CAST(SYSTIMESTAMP AS TIMESTAMP(6))
                          - CAST(a.exec_start_time AS TIMESTAMP(6))
                        AS INTERVAL DAY(9) TO SECOND(6)
                    )
                WHEN j.last_start_date IS NOT NULL THEN
                    CAST(
                        CAST(SYSTIMESTAMP AS TIMESTAMP(6))
                          - CAST(j.last_start_date AS TIMESTAMP(6))
                        AS INTERVAL DAY(9) TO SECOND(6)
                    )
                ELSE NULL
            END AS exec_delta,
            CASE
                WHEN a.ip_address IS NULL THEN NULL
                ELSE a.ip_address||'.'||a.ip_port
            END AS client
        FROM gv$session a
        LEFT JOIN gv$process b
          ON a.inst_id = b.inst_id
         AND a.paddr = b.thread_addr
        LEFT JOIN (
            SELECT
                job_name,
                running_instance,
                last_start_date,
                ROW_NUMBER() OVER (
                    PARTITION BY NVL(running_instance, 1)
                    ORDER BY last_start_date, job_name
                ) AS rn
            FROM dba_scheduler_jobs
            WHERE state = 'RUNNING'
        ) j
          ON a.inst_id = NVL(j.running_instance, a.inst_id)
         AND (
                (a.action IS NOT NULL AND a.action = j.job_name)
             OR (a.module IS NOT NULL AND a.module = j.job_name)
         )
        LEFT JOIN (
            SELECT
                inst_id,
                thread_id,
                ROW_NUMBER() OVER (
                    PARTITION BY inst_id
                    ORDER BY start_time, thread_id
                ) AS rn
            FROM gv$process
            WHERE name = 'DBMS_SCHEDULER'
        ) schd
          ON schd.inst_id = a.inst_id
         AND j.job_name IS NOT NULL
         AND schd.rn = j.rn
        LEFT JOIN v$sqlcommand c
          ON a.command = c.command_type
        WHERE a.TYPE NOT IN ('BACKGROUND')
          AND NVL(NULLIF(TRIM(a.status), ''), 'ACTIVE') NOT IN ('INACTIVE')
    ) x
    ORDER BY exec_ms DESC NULLS LAST
)
/

SELECT 
      a.inst_id,a.sql_id,a.wait_event,count(*) hcount 
FROM gv$session a 
WHERE NVL(NULLIF(TRIM(a.status), ''), 'ACTIVE') NOT IN ('INACTIVE')
  AND a.TYPE NOT IN ('BACKGROUND')
GROUP BY  inst_id,sql_id,wait_event HAVING count(*) >1
ORDER BY hcount
/
