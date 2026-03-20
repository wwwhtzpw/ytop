-- File Name: lock_tx_tree.sql
-- Purpose: display TX lock tree
-- Created: 20251208  by  huangtingzhong

col l             for a1
col b_sid         for a15
col b_sqlid       for a18
col b_event       for a18
col b_user_status for a20
col h_sid         for a15
col h_user_status for a20
col r_lock        for a10
col h_event       for a18
col tid           for a15

WITH lockwait AS (
    SELECT 
        l.inst_id,
        l.sid AS request_sid, 
        l.request AS request_lock, 
        l.id1 AS xid,
        l.id2,
        s.serial# AS request_serial#,
        s.username AS request_username,
        s.status AS request_status,
        s.sql_id,
        s.wait_event
    FROM gv$lock l, gv$session s
    WHERE l.sid = s.sid
      AND l.inst_id = s.inst_id
      AND l.request = 'ROW'
),
blocking_info AS (
    SELECT 
        l.inst_id,
        l.request_sid,
        l.request_serial#,
        l.request_lock,
        l.request_username,
        l.request_status,
        l.xid,
        l.sql_id  AS request_sql_id,
        l.wait_event AS request_event,
        t.inst_id AS blocking_inst_id,
        t.sid AS blocking_sid,
        s.serial# AS blocking_serial#,
        s.username AS blocking_username,
        s.status AS blocking_status,
        s.sql_id,s.wait_event
    FROM lockwait l, gv$transaction t, gv$session s
    WHERE l.xid = t.xid
      AND t.inst_id = l.inst_id
      AND t.sid = s.sid
      AND t.inst_id = s.inst_id
)
SELECT 
    LEVEL||'' AS "L",
    LPAD(' ', 2*(LEVEL-1)) || TO_CHAR(b.inst_id) || ',' || TO_CHAR(b.request_sid) || ',' || TO_CHAR(b.request_serial#) AS b_sid,b.request_sql_id b_sqlid,substr(b.REQUEST_EVENT,1,18) b_event ,
    b.request_username||'_'||b.request_status AS b_user_status,
     TO_CHAR(b.blocking_inst_id) || ',' ||TO_CHAR(b.blocking_sid) || ',' || TO_CHAR(b.blocking_serial#) AS h_sid,
    b.blocking_username||'_'||b.blocking_status AS h_user_status,
    b.request_lock AS r_lock,
    b.SQL_ID h_sqlid,substr(b.wait_event,1,18)  h_event,
    b.xid||'' AS tid
FROM blocking_info b
START WITH NOT EXISTS (
    -- 找到根节点：阻塞者本身不在等待队列中（不在 lockwait 中）
    SELECT 1 FROM lockwait l2
    WHERE l2.request_sid = b.blocking_sid
      AND l2.inst_id = b.inst_id
)
CONNECT BY PRIOR b.request_sid = b.blocking_sid
       AND PRIOR b.inst_id = b.inst_id
ORDER SIBLINGS BY b.request_sid;

