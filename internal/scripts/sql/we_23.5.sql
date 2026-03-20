col SID_TID           for a20
col PROGRAM           for a30
col EVENT             for a30
col USERNAME          for a15
col SQL_ID            for a18
col EXEC_TIME         for a8
col CLIENT            for a20

SELECT 
    sid_tid,
    event,
    username,
    sql_id,
    CASE 
        WHEN exec_seconds < 1 THEN 
            ROUND(exec_seconds * 1000, 0) || 'MS'
        WHEN exec_seconds < 1000 THEN 
            ROUND(exec_seconds, 2) || 'S'
        WHEN exec_seconds < 10000 THEN 
            ROUND(exec_seconds / 1000, 2) || 'KS'
        ELSE 
            ROUND(exec_seconds / 10000, 2) || 'WS'
    END AS exec_time,
    program,
    client 
FROM (
    SELECT 
        a.inst_id||'.'||a.sid||'.'||a.serial#||'.'||b.thread_id AS sid_tid,
        substr(a.wait_event,1,30) AS event,
        a.username AS username,
        substr(a.cli_program,1,30) AS program,
        substr(c.command_name,1,3)||'.'||nvl(a.sql_id,a.PREV_SQL_ID) AS sql_id,
        EXTRACT(DAY FROM (sysdate-a.exec_start_time)) * 86400 +
        EXTRACT(HOUR FROM (sysdate-a.exec_start_time)) * 3600 +
        EXTRACT(MINUTE FROM (sysdate-a.exec_start_time)) * 60 +
        EXTRACT(SECOND FROM (sysdate-a.exec_start_time)) AS exec_seconds,
        a.ip_address||'.'||a.ip_port AS client
    FROM gv$session a, gv$process b, v$SQLCOMMAND c  
    WHERE a.inst_id = b.inst_id 
      AND a.paddr = b.thread_addr  
      AND a.command = c.command_type(+)
      AND a.TYPE NOT IN ('BACKGROUND')
      AND a.status NOT IN ('INACTIVE') 
    ORDER BY exec_seconds DESC
)
/

SELECT 
      a.inst_id,a.sql_id,a.wait_event,count(*) hcount 
FROM gv$session a 
WHERE a.status NOT IN ('INACTIVE')  AND a.TYPE NOT IN ('BACKGROUND') GROUP BY  inst_id,sql_id,wait_event HAVING count(*) >1
ORDER BY hcount
/
