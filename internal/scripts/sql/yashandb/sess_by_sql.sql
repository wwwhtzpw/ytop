-- File Name: sess_by_sql.sql
-- Purpose: List sessions matching SQL text fragment
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/sess_by_sql.sql
-- Note: WAIT_EVENT instead of EVENT; no LAST_CALL_ET/seq#


col i        for a2
col sid_ser  for a16
col username for a15
col status   for a10
col wait_event for a28
col program  for a22
col sql_id   for a15
col sql_text for a50

ACCEPT sql_text PROMPT 'Enter SQL text fragment: '

SELECT TO_CHAR(b.inst_id) AS i,
       TO_CHAR(b.sid) || ':' || TO_CHAR(b.serial#) AS sid_ser,
       b.username,
       b.status,
       SUBSTR(b.wait_event, 1, 28) AS wait_event,
       SUBSTR(NVL(b.cli_program, b.program), 1, 22) AS program,
       NVL(b.sql_id, b.prev_sql_id) AS sql_id,
       SUBSTR(d.sql_text, 1, 50) AS sql_text
  FROM gv$session b, gv$sql d
 WHERE b.inst_id = d.inst_id
   AND NVL(b.sql_id, b.prev_sql_id) = d.sql_id
   AND UPPER(d.sql_text) LIKE '%' || UPPER(TRIM('&&sql_text')) || '%'
   AND b.username IS NOT NULL
 ORDER BY b.inst_id, b.sql_id, b.sid;
