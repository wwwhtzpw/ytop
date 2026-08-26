-- File Name: sess_by_event.sql
-- Purpose: List sessions waiting on a given wait event
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/sess_by_event.sql
-- Note: filter on WAIT_EVENT (not EVENT); no gv$session_wait / audit_actions join


col i          for a2
col sid_ser    for a16
col username   for a15
col status     for a10
col wait_event for a28
col wait_class for a14
col program    for a22
col sql_id     for a15
col machine    for a20

ACCEPT event_name PROMPT 'Enter wait event name fragment (e.g. log file sync): '

SELECT TO_CHAR(b.inst_id) AS i,
       TO_CHAR(b.sid) || ':' || TO_CHAR(b.serial#) AS sid_ser,
       b.username,
       b.status,
       SUBSTR(b.wait_event, 1, 28) AS wait_event,
       SUBSTR(b.wait_class, 1, 14) AS wait_class,
       SUBSTR(NVL(b.cli_program, b.program), 1, 22) AS program,
       NVL(b.sql_id, b.prev_sql_id) AS sql_id,
       SUBSTR(b.machine, 1, 20) AS machine
  FROM gv$session b
 WHERE UPPER(b.wait_event) LIKE '%' || UPPER(TRIM('&&event_name')) || '%'
 ORDER BY b.inst_id, b.wait_event, b.sid;
