-- File Name: find_sql.sql
-- Purpose: YashanDB Find SQL in GV$SQL by text fragment
-- Created: 20251208  by  huangtingzhong

set heading on;
set verify off;

col i                  for a2
col username           for a13
col prog               for a22
col ocategory          for a10
col hash_value         for a10
col execs              for a10
col sqltext            for a100

SELECT TO_CHAR(s.inst_id) AS i,
       s.sql_id,
       s.hash_value || '' AS hash_value,
       s.plan_hash_value AS plan_hash,
       s.executions || '' AS execs,
       ROUND(s.elapsed_time / 1000000, 2) AS etime,
       ROUND(
         (s.elapsed_time / 1000000)
         / DECODE(NVL(s.executions, 0), 0, 1, s.executions),
         2
       ) AS avg_etime,
       u.username,
       s.sql_text AS sqltext
  FROM gv$sql s,
       dba_users u
 WHERE s.sql_text LIKE '%&sql_text%'
   AND s.sql_text NOT LIKE '%from v$sql where sql_text like nvl(%'
   AND s.sql_text NOT LIKE '%from gv$sql where sql_text like nvl(%'
   AND s.sql_id LIKE NVL('&sql_id', s.sql_id)
   AND s.sql_text NOT LIKE 'EXPLAIN PLAN SET%'
   AND u.user_id = s.parsing_user_id
 ORDER BY s.inst_id, s.sql_id, s.child_number
/
