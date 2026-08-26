-- File Name: sess_vm.sql
-- Purpose: Active sessions (we-style) with GV$VMSTAT and memory param header
-- Created: 20260812 by yihan
--


COL i          FOR A2
COL name       FOR A28
COL value      FOR A16
COL mb         FOR A12
COL sid_tid    FOR A18
COL event      FOR A22
COL username   FOR A10
COL sql_id     FOR A15
COL exect      FOR A6
COL program    FOR A14
COL copn       FOR A6
COL cswo       FOR A6
COL swo        FOR A8
COL swi        FOR A8
COL alc        FOR A8
COL iow        FOR A8
COL ext        FOR A6

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | A) Memory / VM parameters by instance (GV$PARAMETER, YAC-aware)        |
PROMPT +------------------------------------------------------------------------+
PROMPT

WITH p AS (
    SELECT inst_id,
           name,
           value,
           CASE
               WHEN REGEXP_LIKE(value, '^[0-9]+$') THEN TO_NUMBER(value)
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+G$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'G$', '')) * 1024 * 1024 * 1024
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+M$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'M$', '')) * 1024 * 1024
               WHEN REGEXP_LIKE(UPPER(value), '^[0-9]+K$')
                   THEN TO_NUMBER(REGEXP_REPLACE(UPPER(value), 'K$', '')) * 1024
               ELSE NULL
           END AS bytes
      FROM gv$parameter
     WHERE UPPER(name) IN (
           'VM_BUFFER_SIZE',
           'WORK_AREA_POOL_SIZE',
           'COLUMNAR_VM_BUFFER_SIZE',
           'COLUMNAR_VM_SWAP_SIZE',
           'DATA_BUFFER_SIZE',
           'SHARE_POOL_SIZE',
           'LARGE_POOL_SIZE',
           'REDO_BUFFER_SIZE',
           'DBWR_BUFFER_SIZE',
           'CURSOR_POOL_SIZE',
           'MEX_POOL_SIZE',
           'PQ_POOL_SIZE'
     )
)
SELECT TO_CHAR(p.inst_id) AS i,
       p.name,
       p.value,
       CASE
           WHEN p.bytes IS NULL THEN NULL
           ELSE TO_CHAR(ROUND(p.bytes / 1024 / 1024, 2))
       END AS mb
  FROM p
 ORDER BY p.inst_id,
          CASE
              WHEN UPPER(p.name) LIKE '%VM%' THEN 0
              ELSE 1
          END,
          p.bytes DESC NULLS LAST,
          p.name
/

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | B) Active sessions + GV$VMSTAT (we-style overview)                     |
PROMPT | Join: gv$session.inst_id/sid = gv$vmstat.inst_id/sid                   |
PROMPT | copn/cswo = pages; swo/swi/alc/iow/ext = times; fmt plain/K/M/G        |
PROMPT +------------------------------------------------------------------------+
PROMPT

SELECT
    sid_tid,
    event,
    username,
    sql_id,
    CASE
        WHEN exec_ms IS NULL THEN 'N/A'
        WHEN exec_ms < 1000 THEN ROUND(exec_ms, 0) || 'MS'
        WHEN exec_ms < 60000 THEN ROUND(exec_ms / 1000, 2) || 'S'
        WHEN exec_ms < 3600000 THEN ROUND(exec_ms / 60000, 2) || 'M'
        WHEN exec_ms < 86400000 THEN ROUND(exec_ms / 3600000, 2) || 'H'
        ELSE ROUND(exec_ms / 86400000, 2) || 'D'
    END AS exect,
    program,
    CASE
        WHEN copn IS NULL THEN NULL
        WHEN ABS(copn) < 1000 THEN TO_CHAR(copn)
        WHEN ABS(copn) < 1000000 THEN TO_CHAR(ROUND(copn / 1000, 1)) || 'K'
        WHEN ABS(copn) < 1000000000 THEN TO_CHAR(ROUND(copn / 1000000, 1)) || 'M'
        ELSE TO_CHAR(ROUND(copn / 1000000000, 1)) || 'G'
    END AS copn,
    CASE
        WHEN cswo IS NULL THEN NULL
        WHEN ABS(cswo) < 1000 THEN TO_CHAR(cswo)
        WHEN ABS(cswo) < 1000000 THEN TO_CHAR(ROUND(cswo / 1000, 1)) || 'K'
        WHEN ABS(cswo) < 1000000000 THEN TO_CHAR(ROUND(cswo / 1000000, 1)) || 'M'
        ELSE TO_CHAR(ROUND(cswo / 1000000000, 1)) || 'G'
    END AS cswo,
    CASE
        WHEN swo IS NULL THEN NULL
        WHEN ABS(swo) < 1000 THEN TO_CHAR(swo)
        WHEN ABS(swo) < 1000000 THEN TO_CHAR(ROUND(swo / 1000, 1)) || 'K'
        WHEN ABS(swo) < 1000000000 THEN TO_CHAR(ROUND(swo / 1000000, 1)) || 'M'
        ELSE TO_CHAR(ROUND(swo / 1000000000, 1)) || 'G'
    END AS swo,
    CASE
        WHEN swi IS NULL THEN NULL
        WHEN ABS(swi) < 1000 THEN TO_CHAR(swi)
        WHEN ABS(swi) < 1000000 THEN TO_CHAR(ROUND(swi / 1000, 1)) || 'K'
        WHEN ABS(swi) < 1000000000 THEN TO_CHAR(ROUND(swi / 1000000, 1)) || 'M'
        ELSE TO_CHAR(ROUND(swi / 1000000000, 1)) || 'G'
    END AS swi,
    CASE
        WHEN alc IS NULL THEN NULL
        WHEN ABS(alc) < 1000 THEN TO_CHAR(alc)
        WHEN ABS(alc) < 1000000 THEN TO_CHAR(ROUND(alc / 1000, 1)) || 'K'
        WHEN ABS(alc) < 1000000000 THEN TO_CHAR(ROUND(alc / 1000000, 1)) || 'M'
        ELSE TO_CHAR(ROUND(alc / 1000000000, 1)) || 'G'
    END AS alc,
    CASE
        WHEN iow IS NULL THEN NULL
        WHEN ABS(iow) < 1000 THEN TO_CHAR(iow)
        WHEN ABS(iow) < 1000000 THEN TO_CHAR(ROUND(iow / 1000, 1)) || 'K'
        WHEN ABS(iow) < 1000000000 THEN TO_CHAR(ROUND(iow / 1000000, 1)) || 'M'
        ELSE TO_CHAR(ROUND(iow / 1000000000, 1)) || 'G'
    END AS iow,
    CASE
        WHEN ext IS NULL THEN NULL
        WHEN ABS(ext) < 1000 THEN TO_CHAR(ext)
        WHEN ABS(ext) < 1000000 THEN TO_CHAR(ROUND(ext / 1000, 1)) || 'K'
        WHEN ABS(ext) < 1000000000 THEN TO_CHAR(ROUND(ext / 1000000, 1)) || 'M'
        ELSE TO_CHAR(ROUND(ext / 1000000000, 1)) || 'G'
    END AS ext
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
        x.copn,
        x.cswo,
        x.swo,
        x.swi,
        x.alc,
        x.iow,
        x.ext
    FROM (
        SELECT
            a.inst_id || '.' || a.sid || '.' || a.serial# || '.'
              || NVL(TO_CHAR(NVL(b.thread_id, schd.thread_id)), '-') AS sid_tid,
            SUBSTR(a.wait_event, 1, 22) AS event,
            SUBSTR(a.username, 1, 10) AS username,
            SUBSTR(NVL(a.cli_program, NVL(j.job_name, a.module)), 1, 14) AS program,
            SUBSTR(c.command_name, 1, 3) || '.' || NVL(a.sql_id, a.sql_id) AS sql_id,
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
            v.curr_open AS copn,
            v.curr_swap_out AS cswo,
            v.swap_out_count AS swo,
            v.swap_in_count AS swi,
            v.alloc_count AS alc,
            v.io_wait_count AS iow,
            v.extend_count AS ext
        FROM gv$session a
        LEFT JOIN gv$process b
          ON a.inst_id = b.inst_id
         AND a.paddr = b.thread_addr
        LEFT JOIN gv$vmstat v
          ON a.inst_id = v.inst_id
         AND a.sid = v.sid
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
          AND NOT (a.INST_ID = TO_NUMBER(SYS_CONTEXT('USERENV', 'INSTANCE'))
           AND a.SID = TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')))
    ) x
    ORDER BY
        NVL(x.swo, 0) DESC,
        NVL(x.cswo, 0) DESC,
        NVL(x.copn, 0) DESC,
        exec_ms DESC NULLS LAST
)
/
