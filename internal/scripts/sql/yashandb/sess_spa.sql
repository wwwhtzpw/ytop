-- File Name: sess_spa.sql
-- Purpose: Active sessions (we-style) with GV$SESSION_SPA sizes
-- Created: 20260812 by yihan
--
-- Notes:
--   Part A: SPA-related gv$parameter (per-instance; YAC-aware).
--   Part B: we.sql session overview LEFT JOIN pivoted gv$session_spa.
--   SPA = Session Private Area; USE_SIZE unit = bytes (doc).
--   Columns: vm/cvm/lrg/app/pq/tot (adaptive B/K/M/G, 1024-based).
--   Doc: https://doc.yashandb.com/yashandb/23.4/.../V$SESSION_SPA.html

COL i          FOR A2
COL name       FOR A28
COL value      FOR A16
COL mb         FOR A12
COL sid_tid    FOR A18
COL event      FOR A20
COL username   FOR A10
COL sql_id     FOR A15
COL exect      FOR A6
COL program    FOR A12
COL vm         FOR A8
COL cvm        FOR A8
COL lrg        FOR A8
COL app        FOR A8
COL pq         FOR A8
COL tot        FOR A8

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | A) SPA-related parameters by instance (GV$PARAMETER, YAC-aware)        |
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
           'COLUMNAR_VM_BUFFER_SIZE',
           'COLUMNAR_VM_SWAP_SIZE',
           'LARGE_POOL_SIZE',
           'WORK_AREA_POOL_SIZE',
           'WORK_AREA_HEAP_SIZE',
           'WORK_AREA_STACK_SIZE',
           'PQ_POOL_SIZE',
           'SHARE_POOL_SIZE',
           'DATA_BUFFER_SIZE'
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
              WHEN UPPER(p.name) LIKE '%VM%'
                OR UPPER(p.name) LIKE 'WORK_AREA%'
                OR UPPER(p.name) LIKE 'LARGE%'
                OR UPPER(p.name) LIKE 'PQ%' THEN 0
              ELSE 1
          END,
          p.bytes DESC NULLS LAST,
          p.name
/

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | B) Active sessions + GV$SESSION_SPA (we-style overview)                |
PROMPT | Join: gv$session.inst_id/sid = gv$session_spa.inst_id/sid              |
PROMPT | vm/cvm/lrg/app/pq = USE_SIZE bytes; tot=sum; fmt B/K/M/G (1024)        |
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
        WHEN vm_b IS NULL THEN NULL
        WHEN ABS(vm_b) < 1024 THEN TO_CHAR(vm_b) || 'B'
        WHEN ABS(vm_b) < 1048576 THEN TO_CHAR(ROUND(vm_b / 1024, 1)) || 'K'
        WHEN ABS(vm_b) < 1073741824 THEN TO_CHAR(ROUND(vm_b / 1048576, 1)) || 'M'
        ELSE TO_CHAR(ROUND(vm_b / 1073741824, 2)) || 'G'
    END AS vm,
    CASE
        WHEN cvm_b IS NULL THEN NULL
        WHEN ABS(cvm_b) < 1024 THEN TO_CHAR(cvm_b) || 'B'
        WHEN ABS(cvm_b) < 1048576 THEN TO_CHAR(ROUND(cvm_b / 1024, 1)) || 'K'
        WHEN ABS(cvm_b) < 1073741824 THEN TO_CHAR(ROUND(cvm_b / 1048576, 1)) || 'M'
        ELSE TO_CHAR(ROUND(cvm_b / 1073741824, 2)) || 'G'
    END AS cvm,
    CASE
        WHEN lrg_b IS NULL THEN NULL
        WHEN ABS(lrg_b) < 1024 THEN TO_CHAR(lrg_b) || 'B'
        WHEN ABS(lrg_b) < 1048576 THEN TO_CHAR(ROUND(lrg_b / 1024, 1)) || 'K'
        WHEN ABS(lrg_b) < 1073741824 THEN TO_CHAR(ROUND(lrg_b / 1048576, 1)) || 'M'
        ELSE TO_CHAR(ROUND(lrg_b / 1073741824, 2)) || 'G'
    END AS lrg,
    CASE
        WHEN app_b IS NULL THEN NULL
        WHEN ABS(app_b) < 1024 THEN TO_CHAR(app_b) || 'B'
        WHEN ABS(app_b) < 1048576 THEN TO_CHAR(ROUND(app_b / 1024, 1)) || 'K'
        WHEN ABS(app_b) < 1073741824 THEN TO_CHAR(ROUND(app_b / 1048576, 1)) || 'M'
        ELSE TO_CHAR(ROUND(app_b / 1073741824, 2)) || 'G'
    END AS app,
    CASE
        WHEN pq_b IS NULL THEN NULL
        WHEN ABS(pq_b) < 1024 THEN TO_CHAR(pq_b) || 'B'
        WHEN ABS(pq_b) < 1048576 THEN TO_CHAR(ROUND(pq_b / 1024, 1)) || 'K'
        WHEN ABS(pq_b) < 1073741824 THEN TO_CHAR(ROUND(pq_b / 1048576, 1)) || 'M'
        ELSE TO_CHAR(ROUND(pq_b / 1073741824, 2)) || 'G'
    END AS pq,
    CASE
        WHEN tot_b IS NULL THEN NULL
        WHEN ABS(tot_b) < 1024 THEN TO_CHAR(tot_b) || 'B'
        WHEN ABS(tot_b) < 1048576 THEN TO_CHAR(ROUND(tot_b / 1024, 1)) || 'K'
        WHEN ABS(tot_b) < 1073741824 THEN TO_CHAR(ROUND(tot_b / 1048576, 1)) || 'M'
        ELSE TO_CHAR(ROUND(tot_b / 1073741824, 2)) || 'G'
    END AS tot
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
        x.vm_b,
        x.cvm_b,
        x.lrg_b,
        x.app_b,
        x.pq_b,
        x.tot_b
    FROM (
        SELECT
            a.inst_id || '.' || a.sid || '.' || a.serial# || '.'
              || NVL(TO_CHAR(NVL(b.thread_id, schd.thread_id)), '-') AS sid_tid,
            SUBSTR(a.wait_event, 1, 20) AS event,
            SUBSTR(a.username, 1, 10) AS username,
            SUBSTR(NVL(a.cli_program, NVL(j.job_name, a.module)), 1, 12) AS program,
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
            spa.vm_b,
            spa.cvm_b,
            spa.lrg_b,
            spa.app_b,
            spa.pq_b,
            spa.tot_b
        FROM gv$session a
        LEFT JOIN gv$process b
          ON a.inst_id = b.inst_id
         AND a.paddr = b.thread_addr
        LEFT JOIN (
            SELECT inst_id,
                   sid,
                   SUM(CASE WHEN type = 'vm buffer pool'
                            THEN use_size ELSE 0 END) AS vm_b,
                   SUM(CASE WHEN type = 'columnar vm buffer pool'
                            THEN use_size ELSE 0 END) AS cvm_b,
                   SUM(CASE WHEN type = 'large pool'
                            THEN use_size ELSE 0 END) AS lrg_b,
                   SUM(CASE WHEN type = 'app pool'
                            THEN use_size ELSE 0 END) AS app_b,
                   SUM(CASE WHEN type = 'pq pool'
                            THEN use_size ELSE 0 END) AS pq_b,
                   SUM(NVL(use_size, 0)) AS tot_b
              FROM gv$session_spa
             GROUP BY inst_id, sid
        ) spa
          ON a.inst_id = spa.inst_id
         AND a.sid = spa.sid
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
        NVL(x.tot_b, 0) DESC,
        NVL(x.vm_b, 0) DESC,
        NVL(x.cvm_b, 0) DESC,
        exec_ms DESC NULLS LAST
)
/
