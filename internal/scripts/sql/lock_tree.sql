-- File Name: lock_tree.sql
-- Purpose: display lock tree of row and table
-- Created: 20251208  by  huangtingzhong

col l             for a1
col b_sid         for a15
col b_sqlid       for a18
col h_sqlid       for a18
col b_event       for a18
col b_user        for a15
col h_user        for a15
col h_sid         for a15
col b_user        for a15
col h_event       for a18
col resourceid    for a15
col lock_type     for a10
col h_seconds     for a10
col b_seconds     for a10
col table_name    for a30

WITH 
row_lockwait AS (
    SELECT 
        l.inst_id,
        l.sid AS request_sid, 
        l.request AS request_lock, 
        l.id1 AS resource_id,
        s.serial# AS request_serial#,
        s.username AS request_username,
        'ROW->ROW' AS lock_type,
        s.sql_id,substr(s.wait_event,1,18) event,sysdate-s.EXEC_START_TIME exec_time,s.EXEC_STATUS,
        NULL AS table_name
    FROM gv$lock l, gv$session s
    WHERE l.sid = s.sid
      AND l.inst_id = s.inst_id
      AND l.request = 'ROW'
),
row_blocking AS (
    SELECT 
        r.inst_id,
        r.request_sid,
        r.request_serial#,
        r.request_username,
        r.request_lock,
        r.lock_type,
        r.resource_id,
        r.table_name,
        s.inst_id AS blocking_inst,
        t.sid AS blocking_sid,
        s.serial# AS blocking_serial#,
        s.username AS blocking_username,
        r.sql_id b_sqlid,r.event b_event,r.exec_time b_exec_time,r.EXEC_STATUS b_exec_status,
        s.sql_id h_sqlid,substr(s.wait_event,1,18) h_event,sysdate-s.EXEC_START_TIME h_exec_time,s.EXEC_STATUS h_exec_status
    FROM row_lockwait r, gv$transaction t, gv$session s
    WHERE r.resource_id = t.xid
      AND t.inst_id = r.inst_id
      AND t.sid = s.sid
      AND t.inst_id = s.inst_id
),
ts_lockwait AS (
    SELECT 
        l.inst_id,
        l.sid AS request_sid, 
        l.request AS request_lock, 
        l.id1 AS resource_id,
        s.serial# AS request_serial#,
        s.username AS request_username,
        'TS->TX' AS lock_type,s.sql_id,substr(s.wait_event,1,18) event,sysdate-s.EXEC_START_TIME exec_time,s.EXEC_STATUS
    FROM gv$lock l, gv$session s
    WHERE l.sid = s.sid
      AND l.inst_id = s.inst_id
      AND l.request = 'TS'
),
ts_blocking AS (
    SELECT DISTINCT
        w.inst_id,
        w.request_sid,
        w.request_serial#,
        w.request_username,
        w.request_lock,
        w.lock_type,
        w.resource_id,
        o.owner || '.' || o.object_name AS table_name,
        gl.inst_id AS blocking_inst,
        gl.sid AS blocking_sid,
        s.serial# AS blocking_serial#,
        s.username AS blocking_username,
        w.sql_id b_sqlid,w.event b_event,w.exec_time b_exec_time,w.EXEC_STATUS b_exec_status,
        s.sql_id h_sqlid,substr(s.wait_event,1,18) h_event,sysdate-s.EXEC_START_TIME h_exec_time,s.EXEC_STATUS h_exec_status
    FROM ts_lockwait w, gv$lock gl, gv$session s, dba_objects o
    WHERE gl.id1 = w.resource_id
      AND (gl.request = 'TX' or gl.lmode = 'TX')
      AND gl.inst_id = w.inst_id
      AND gl.sid = s.sid
      AND gl.inst_id = s.inst_id
      AND w.resource_id = o.object_id(+)
),
-- 3. 表锁等待 - TX锁等待TS锁（独占锁等待共享锁）
tx_lockwait AS (
    SELECT 
        l.inst_id,
        l.sid AS request_sid, 
        l.request AS request_lock, 
        l.id1 AS resource_id,
        s.serial# AS request_serial#,
        s.username AS request_username,
        'TX->TS' AS lock_type,s.sql_id,substr(s.wait_event,1,18) event,sysdate-s.EXEC_START_TIME exec_time,s.EXEC_STATUS
    FROM gv$lock l, gv$session s
    WHERE l.sid = s.sid
      AND l.inst_id = s.inst_id
      AND l.request = 'TX'
),
tx_blocking AS (
    SELECT 
        w.inst_id,
        w.request_sid,
        w.request_serial#,
        w.request_username,
        w.request_lock,
        w.lock_type,
        w.resource_id,
        o.owner || '.' || o.object_name AS table_name,
        gl.inst_id AS blocking_inst,
        gl.sid AS blocking_sid,
        s.serial# AS blocking_serial#,
        s.username AS blocking_username,
        w.sql_id b_sqlid,w.event b_event,w.exec_time b_exec_time,w.EXEC_STATUS b_exec_status,
        s.sql_id h_sqlid,substr(s.wait_event,1,18) h_event,sysdate-s.EXEC_START_TIME h_exec_time,s.EXEC_STATUS h_exec_status
    FROM tx_lockwait w, gv$lock gl, gv$session s, dba_objects o
    WHERE gl.id1 = w.resource_id
      AND gl.lmode = 'TS'
      AND gl.inst_id = w.inst_id
      AND gl.sid = s.sid
      AND gl.inst_id = s.inst_id
      AND w.resource_id = o.object_id(+)
),
all_lock_chain AS (
    SELECT * FROM row_blocking
    UNION ALL
    SELECT * FROM ts_blocking
    UNION ALL
    SELECT * FROM tx_blocking
)
SELECT 
    LEVEL||'' AS "L",
    LPAD(' ', 2*(LEVEL-1)) || TO_CHAR(a.inst_id) || '.' || TO_CHAR(a.request_sid) || '.' || TO_CHAR(a.request_serial#) AS b_sid,
    a.request_username AS b_user,b_sqlid,b_event,trunc(EXTRACT(DAY FROM (b_exec_time)) * 86400 +
        EXTRACT(HOUR FROM (b_exec_time)) * 3600 +
        EXTRACT(MINUTE FROM (b_exec_time)) * 60 +
        EXTRACT(SECOND FROM (b_exec_time)))||'' AS b_seconds,
        -- b_exec_status,
    a.lock_type AS lock_type,
    a.table_name AS table_name,
    to_char(a.blocking_inst)||'.'||TO_CHAR(a.blocking_sid) || '.' || TO_CHAR(a.blocking_serial#) AS h_sid,
    a.blocking_username AS h_user,h_sqlid,h_event,trunc(EXTRACT(DAY FROM (h_exec_time)) * 86400 +
        EXTRACT(HOUR FROM (h_exec_time)) * 3600 +
        EXTRACT(MINUTE FROM (h_exec_time)) * 60 +
        EXTRACT(SECOND FROM (h_exec_time)))||'' AS h_seconds,
        -- h_exec_status,
    TO_CHAR(a.resource_id) AS  resourceid
FROM all_lock_chain a
START WITH NOT EXISTS (
    SELECT 1 FROM all_lock_chain a2
    WHERE a2.request_sid = a.blocking_sid
      AND a2.inst_id = a.inst_id
)
CONNECT BY PRIOR a.request_sid = a.blocking_sid
       AND PRIOR a.inst_id = a.inst_id
ORDER SIBLINGS BY a.lock_type, a.request_sid;

