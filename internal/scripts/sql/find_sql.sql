-- File Name: find_sql.sql
-- Purpose: display SQL ID and basic information based on input SQL text
-- Created: 20251208  by  huangtingzhong
set heading on;
set verify off;

col username format a13
col prog format a22
col sqltext format a190
col ocategory format a10
col hash_value         for a10
col execs              for a10
col sqltext            for a100

SELECT sql_id,
--       child_number,
       hash_value||'',
       plan_hash_value plan_hash,
       executions||'' execs,
       round(elapsed_time / 1000000,2) etime,
         round((elapsed_time / 1000000)
       / DECODE (NVL (executions, 0), 0, 1, executions),2)
          avg_etime,
       u.username,
       sql_text sqltext
  FROM v$sqlarea s, dba_users u
 WHERE     sql_text  LIKE '%&sql_text%'
       AND sql_text NOT LIKE '%from v$sql where sql_text like nvl(%'
       AND sql_id LIKE NVL ('&sql_id', sql_id) and sql_text not like 'EXPLAIN PLAN SET%'
       AND u.user_id = s.parsing_user_id
/
