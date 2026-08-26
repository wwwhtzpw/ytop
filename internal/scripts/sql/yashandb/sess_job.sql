-- File Name: sess_job.sql
-- Purpose: YashanDB running scheduler jobs with session wait overview (YAC)
-- Created: 20260730 by huangtingzhong
--
-- Notes:
--   Style aligned with we.sql (sid_tid / event / exec_time). Uses gv$ for YAC.
--   Joins RUNNING DBA_SCHEDULER_JOBS to gv$session via action/module = job_name.
--   Job sessions often have NULL paddr; thread_id falls back to gv$process
--   name='DBMS_SCHEDULER' matched by start order within the instance.
--   EXEC_TIME = SYSTIMESTAMP - last_start_date (elapsed since job started).
--   Display width budget <= 200 (col formats + 1-space separators; see sql-script-guide §3.2).

-- width budget (<=200):
-- sid_tid20 event20 username10 sql_id18 exec6 job18 state9 inst1 params28 program16 client14
-- = 160 + 11 spaces = 171

col SID_TID              for a20
col EVENT                for a20
col USERNAME             for a10
col SQL_ID               for a18
col EXECT                for a6
col JOB_NAME             for a18
col STATE                for a9
col I                    for a1
col PARAMS               for a28
col PROGRAM              for a16
col CLIENT               for a14

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
    job_name,
    state,
    i,
    params,
    program,
    client
FROM (
    SELECT
        x.sid_tid,
        x.event,
        x.username,
        x.sql_id,
        GREATEST(0,
            EXTRACT(DAY FROM x.exec_delta) * 86400000 +
            EXTRACT(HOUR FROM x.exec_delta) * 3600000 +
            EXTRACT(MINUTE FROM x.exec_delta) * 60000 +
            EXTRACT(SECOND FROM x.exec_delta) * 1000
        ) AS exec_ms,
        x.job_name,
        x.state,
        x.i,
        x.params,
        x.program,
        x.client
    FROM (
        SELECT
            SUBSTR(
                NVL(TO_CHAR(a.inst_id), TO_CHAR(j.running_instance))
                  ||'.'||NVL(TO_CHAR(a.sid), '-')
                  ||'.'||NVL(TO_CHAR(a.serial#), '-')
                  ||'.'||NVL(TO_CHAR(NVL(b.thread_id, schd.thread_id)), '-'),
                1, 20
            ) AS sid_tid,
            SUBSTR(a.wait_event, 1, 20) AS event,
            SUBSTR(NVL(a.username, j.owner), 1, 10) AS username,
            CASE
                WHEN a.sql_id IS NULL THEN NULL
                ELSE SUBSTR(SUBSTR(c.command_name, 1, 3)||'.'||a.sql_id, 1, 18)
            END AS sql_id,
            -- elapsed: job start (last_start_date) -> now
            CASE
                WHEN j.last_start_date IS NULL THEN NULL
                ELSE CAST(
                    CAST(SYSTIMESTAMP AS TIMESTAMP(6))
                      - CAST(j.last_start_date AS TIMESTAMP(6))
                    AS INTERVAL DAY(9) TO SECOND(6)
                )
            END AS exec_delta,
            SUBSTR(j.job_name, 1, 18) AS job_name,
            SUBSTR(j.state, 1, 9) AS state,
            -- running_instance: single digit display (YAC instance id)
            SUBSTR(TO_CHAR(NVL(j.running_instance, 0)), 1, 1) AS i,
            SUBSTR(
                'JQ='||p.job_queue_processes||';RUN='||p.running_jobs,
                1, 28
            ) AS params,
            SUBSTR(NVL(a.cli_program, schd.name), 1, 16) AS program,
            CASE
                WHEN a.ip_address IS NULL THEN NULL
                ELSE SUBSTR(a.ip_address||'.'||a.ip_port, 1, 14)
            END AS client
        FROM (
            SELECT
                owner,
                job_name,
                state,
                job_type,
                running_instance,
                last_start_date,
                ROW_NUMBER() OVER (
                    PARTITION BY NVL(running_instance, 1)
                    ORDER BY last_start_date, job_name
                ) AS rn
            FROM dba_scheduler_jobs
            WHERE state = 'RUNNING'
        ) j
        CROSS JOIN (
            SELECT
                MAX(CASE WHEN name = 'JOB_QUEUE_PROCESSES' THEN value END)
                    AS job_queue_processes,
                (SELECT COUNT(*) FROM dba_scheduler_jobs WHERE state = 'RUNNING')
                    AS running_jobs
            FROM v$parameter
            WHERE name = 'JOB_QUEUE_PROCESSES'
        ) p
        LEFT JOIN gv$session a
          ON a.inst_id = NVL(j.running_instance, a.inst_id)
         AND (
                (a.action IS NOT NULL AND a.action = j.job_name)
             OR (a.module IS NOT NULL AND a.module = j.job_name)
         )
        LEFT JOIN gv$process b
          ON a.inst_id = b.inst_id
         AND a.paddr = b.thread_addr
        LEFT JOIN (
            SELECT
                inst_id,
                thread_id,
                name,
                start_time,
                ROW_NUMBER() OVER (
                    PARTITION BY inst_id
                    ORDER BY start_time, thread_id
                ) AS rn
            FROM gv$process
            WHERE name = 'DBMS_SCHEDULER'
        ) schd
          ON schd.inst_id = NVL(j.running_instance, schd.inst_id)
         AND schd.rn = j.rn
        LEFT JOIN v$sqlcommand c
          ON a.command = c.command_type
    ) x
    ORDER BY exec_ms DESC NULLS LAST, job_name
)
/
