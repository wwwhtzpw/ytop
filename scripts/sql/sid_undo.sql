col SID_TID           for a20
col PROGRAM           for a30
col event_status      for a35
col USERNAME          for a15
col SQL_ID            for a18
col EXEC_TIME         for a8
col tran_time         for a8
col CLIENT            for a20
col used_ublk         for a10

SELECT sid_tid,event_status,username,program,sql_id, 
    CASE 
        WHEN exec_seconds < 1 THEN 
            ROUND(exec_seconds * 1000, 0) || 'MS'
        WHEN exec_seconds < 1000 THEN 
            ROUND(exec_seconds, 2) || 'S'
        WHEN exec_seconds < 10000 THEN 
            ROUND(exec_seconds / 1000, 2) || 'KS'
        ELSE 
            ROUND(exec_seconds / 10000, 2) || 'WS'
    END AS exec_time,used_ublk||'' used_ublk,
        CASE 
        WHEN trans_seconds < 1 THEN 
            ROUND(trans_seconds * 1000, 0) || 'MS'
        WHEN trans_seconds < 1000 THEN 
            ROUND(trans_seconds, 2) || 'S'
        WHEN trans_seconds < 10000 THEN 
            ROUND(trans_seconds / 1000, 2) || 'KS'
        ELSE 
            ROUND(trans_seconds / 10000, 2) || 'WS'
    END AS tran_time,client
    FROM (SELECT 
        a.inst_id||'.'||a.sid||'.'||a.serial#||'.'||b.thread_id AS sid_tid,
        substr(a.wait_event,1,30)||':'||a.status AS event_status,
        a.username AS username,
        substr(a.cli_program,1,30) AS program,
        substr(c.command_name,1,3)||'.'||nvl(a.sql_id,a.sql_id) AS sql_id,
        EXTRACT(DAY FROM (sysdate-a.exec_start_time)) * 86400 +
        EXTRACT(HOUR FROM (sysdate-a.exec_start_time)) * 3600 +
        EXTRACT(MINUTE FROM (sysdate-a.exec_start_time)) * 60 +
        EXTRACT(SECOND FROM (sysdate-a.exec_start_time)) AS exec_seconds,
        a.ip_address||'.'||a.ip_port AS client,used_ublk,
             (sysdate-d.start_date)*24*60*60 as trans_seconds
    FROM gv$session a, gv$process b, v$SQLCOMMAND c ,gv$transaction d
    WHERE a.inst_id = b.inst_id 
      AND a.paddr = b.thread_addr  
      AND a.inst_id=d.inst_id
      AND a.sid=d.sid
      AND a.xid=d.xid
      AND a.command = c.command_type(+) ORDER BY trans_seconds,used_ublk)
/
