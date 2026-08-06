-- File Name: sql_stat.sql
-- Purpose: SQL exec stats from v$sqlarea v$sql AWR
-- Created: 20260728  by  huangtingzhong
--
-- Usage: ytop -f sql_stat.sql
-- Extracted from sql.sql (v$sqlarea / v$sql / AWR WRH$_SQLSTAT).

SET VERIFY OFF
SET FEEDBACK OFF

UNDEFINE sqlid

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | SQL execution performance statistics                                   |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT sqlid PROMPT 'Enter sqlid: '

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from v$sqlarea                |
PROMPT +------------------------------------------------------------------------+
PROMPT

col  EXEC                   for   a8
col  CPU_P_E                for   a10
col  ELA_P_E                for   a10
col  DISK_P_E               for   a10
col  GET_P_E                for   a10
col  ROWS_P_E               for   a10
col  APP_W_P                for   a10
col  CLU_W_P                for   a10
col  IO_W_P                 for   a10
col  ROWS_P_F               for   a10
col  CON_W_P                for   a10
col  PLSQL_W_P              for   a10
col  OUTLINE                for   a20
col  F_L_TIME               for   a15
col  APP_P_E                for   a10
col  CON_P_E                for   a10
col  USERNAME               for   a15
col  C                      for   a3
col  PHV                    for   a12
col  IOW_P_E                for   a10
col  WRITE_P_E              for   a10
col  i                      for   a1
col  SORTS_P_E              for   a10
col  SEGMENT_NAME           for   a25

SELECT PLAN_HASH_VALUE||'' PHV,
        CASE
        WHEN EXECUTIONS < 1000 THEN TO_CHAR(EXECUTIONS)
        WHEN EXECUTIONS < 10000 THEN TO_CHAR(ROUND(EXECUTIONS / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(EXECUTIONS / 10000, 2)) || 'W'
        END AS EXEC,
       CASE
        WHEN CPU_TIME IS NULL THEN NULL
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
        END AS CPU_P_E,
       CASE
        WHEN ELAPSED_TIME IS NULL THEN NULL
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
        END AS ELA_P_E,
       CASE
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
        END AS DISK_P_E,
       CASE
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS GET_P_E,
       CASE
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS ROWS_P_E,
       CASE
        WHEN fetches/ DECODE(executions, 0, 1, executions) < 1000 THEN TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions),2))
        WHEN fetches / DECODE(executions, 0, 1, executions) < 10000 THEN TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions) / 10000, 2)) || 'W'
        END AS ROWS_P_F,
      CASE
        WHEN APPLICATION_WAIT_TIME IS NULL THEN NULL
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS APP_W_P,
        CASE
        WHEN CONCURRENCY_WAIT_TIME IS NULL THEN NULL
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CON_W_P,
         case
               WHEN CLUSTER_WAIT_TIME IS NULL THEN NULL
               WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CLU_W_P,
               CASE
        WHEN USER_IO_WAIT_TIME IS NULL THEN NULL
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS IO_W_P,
    CASE
        WHEN PLSQL_EXEC_TIME IS NULL THEN NULL
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS PLSQL_W_P,
    CAST(NULL AS VARCHAR(64)) AS outline
  FROM v$sqlarea
where sql_id = '&&sqlid';

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from v$sql                 |
PROMPT +------------------------------------------------------------------------+
PROMPT


SELECT
    CASE
        WHEN EXECUTIONS < 1000 THEN TO_CHAR(EXECUTIONS)
        WHEN EXECUTIONS < 10000 THEN TO_CHAR(ROUND(EXECUTIONS / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(EXECUTIONS / 10000, 2)) || 'W'
    END AS EXEC,
    PLAN_HASH_VALUE||'' PHV,
    child_number||'' AS c,
    PARSING_SCHEMA_NAME AS username,
      CASE
        WHEN CPU_TIME IS NULL THEN NULL
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CPU_P_E,
    CASE
        WHEN ELAPSED_TIME IS NULL THEN NULL
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS ELA_P_E,
    CASE
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS DISK_P_E,
    CASE
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS GET_P_E,
    CASE
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS ROWS_P_E,
    CASE
        WHEN ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES),2))
        WHEN ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) / 10000, 2)) || 'W'
    END AS ROWS_P_F,
  CASE
        WHEN APPLICATION_WAIT_TIME IS NULL THEN NULL
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS APP_P_E,
        CASE
        WHEN CONCURRENCY_WAIT_TIME IS NULL THEN NULL
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CON_P_E,
        CASE
        WHEN CLUSTER_WAIT_TIME IS NULL THEN NULL
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CLU_W_P,
        CASE
        WHEN USER_IO_WAIT_TIME IS NULL THEN NULL
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS IO_W_P,
        CASE
        WHEN PLSQL_EXEC_TIME IS NULL THEN NULL
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000, 2) || 's'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS PLSQL_W_P,
    SUBSTR(FIRST_LOAD_TIME, 6, 10) || '.' || SUBSTR(LAST_LOAD_TIME, 6, 10) AS f_l_time
FROM v$sql s
WHERE sql_id = '&&sqlid'
ORDER BY plan_hash_value;


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from awr (END_INTERVAL_TIME > SYSDATE-5)                  |
PROMPT +------------------------------------------------------------------------+
PROMPT

SELECT TO_CHAR (END_INTERVAL_TIME, 'dd hh24') end_time,
         TRIM (a.instance_number) i,
         a.parsing_schema_name as username,
         a.plan_hash_value||'' PHV,
      CASE
        WHEN executions_delta < 1000 THEN TO_CHAR(executions_delta)
        WHEN executions_delta < 10000 THEN TO_CHAR(ROUND(executions_delta / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(executions_delta / 10000, 2)) || 'W'
    END AS EXEC,
    CASE
        WHEN cpu_time_delta IS NULL THEN NULL
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CPU_P_E,
    CASE
        WHEN elapsed_time_delta IS NULL THEN NULL
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS ELA_P_E,
    CASE
        WHEN disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS DISK_P_E,
        CASE
        WHEN BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS GET_P_E,
    CASE
        WHEN rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS ROWS_P_E,
    CASE
        WHEN fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS ROWS_P_F,
    CASE
        WHEN direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS WRITE_P_E,
    CASE
        WHEN IOWAIT_DELTA IS NULL THEN NULL
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS IOW_P_E,
    -- CASE
    --     WHEN parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
    --     WHEN parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
    --     ELSE TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    -- END AS PARSE_P_E,
    CASE
        WHEN sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS SORTS_P_E,
    CASE
        WHEN apwait_delta IS NULL THEN NULL
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS APP_P_E,
    CASE
        WHEN ccwait_delta IS NULL THEN NULL
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CON_P_E,
    CASE
        WHEN clwait_delta IS NULL THEN NULL
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS CLU_W_P,
    CASE
        WHEN plsexec_time_delta IS NULL THEN NULL
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 < 60 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000, 2) || 's'
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 < 60 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60, 2) || 'm'
        ELSE ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 1000 / 60 / 60, 2) || 'h'
    END AS PLSQL_W_P
    FROM WRH$_SQLSTAT  a, WRM$_SNAPSHOT b
   WHERE     a.sql_id = '&&sqlid'
         AND a.snap_id = b.snap_id
         AND b.END_INTERVAL_TIME > SYSDATE - 5
         AND a.instance_number = b.instance_number
ORDER BY 1
/
