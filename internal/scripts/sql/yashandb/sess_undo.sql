-- File Name: sess_undo.sql
-- Purpose: Per-session UNDO blocks and size MB (optional SID filter)
-- Created: 20250615  by  huangtingzhong
-- Updated: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/sess_undosize.sql


col SessID       for a24
col UserName     for a18
col WaitStat     for a44
col Program      for a44
col SqlID        for a28
col ExecT        for a5
col Ublk         for a9
col UblkMb       for a10
col TxAge        for a5
col Client       for a30
col Xid          for a18
col TxStat       for a6
col Resid        for a5
col Isol         for a8
col Cmd          for a6

ACCEPT sid PROMPT 'Enter SID (empty=all): '

SELECT SUBSTR(b.sid_tid, 1, 24) AS sess_id,
       SUBSTR(NVL(b.username, '-'), 1, 18) AS user_name,
       SUBSTR(NVL(b.wait_event, '-') || ':' || NVL(b.status, '-'), 1, 44) AS wait_stat,
       SUBSTR(NVL(b.cli_program, '-'), 1, 44) AS program,
       SUBSTR(NVL(b.cmd_sql, '-'), 1, 28) AS sql_id,
       SUBSTR(
         CASE
           WHEN b.exec_sec < 1 THEN TO_CHAR(ROUND(b.exec_sec * 1000)) || 'MS'
           WHEN b.exec_sec < 10000 THEN TO_CHAR(b.exec_sec) || 'S'
           WHEN b.exec_sec < 36000 THEN TO_CHAR(ROUND(b.exec_sec / 60)) || 'M'
           ELSE TO_CHAR(ROUND(b.exec_sec / 3600)) || 'H'
         END, 1, 5) AS exec_t,
       SUBSTR(TO_CHAR(b.used_ublk), 1, 9) AS ublk,
       SUBSTR(TO_CHAR(ROUND(b.used_ublk * b.bs / 1024 / 1024, 3)), 1, 10) AS ublk_mb,
       SUBSTR(
         CASE
           WHEN b.tx_sec < 1 THEN TO_CHAR(ROUND(b.tx_sec * 1000)) || 'MS'
           WHEN b.tx_sec < 10000 THEN TO_CHAR(b.tx_sec) || 'S'
           WHEN b.tx_sec < 36000 THEN TO_CHAR(ROUND(b.tx_sec / 60)) || 'M'
           ELSE TO_CHAR(ROUND(b.tx_sec / 3600)) || 'H'
         END, 1, 5) AS tx_age,
       SUBSTR(NVL(b.ip_address, '-') || ':' || NVL(TO_CHAR(b.ip_port), '-'), 1, 30) AS client,
       SUBSTR(TO_CHAR(b.xid), 1, 18) AS xid,
       SUBSTR(NVL(b.tx_status, '-'), 1, 6) AS tx_stat,
       SUBSTR(NVL(b.residual, '-'), 1, 5) AS resid,
       SUBSTR(NVL(b.isolation_level, '-'), 1, 8) AS isol,
       SUBSTR(NVL(TO_CHAR(b.command), '-'), 1, 6) AS cmd
  FROM (
        SELECT a.inst_id || '.' || a.sid || '.' || a.serial# || '.' ||
               NVL(TO_CHAR(b.thread_id), '-') AS sid_tid,
               a.username,
               a.status,
               a.wait_event,
               a.cli_program,
               SUBSTR(c.command_name, 1, 3) || '.' || NVL(a.sql_id, '-') AS cmd_sql,
               TRUNC(EXTRACT(DAY FROM (SYSDATE - a.exec_start_time)) * 86400 +
                     EXTRACT(HOUR FROM (SYSDATE - a.exec_start_time)) * 3600 +
                     EXTRACT(MINUTE FROM (SYSDATE - a.exec_start_time)) * 60 +
                     EXTRACT(SECOND FROM (SYSDATE - a.exec_start_time))) AS exec_sec,
               a.ip_address,
               a.ip_port,
               d.used_ublk,
               d.xid,
               d.status AS tx_status,
               d.residual,
               d.isolation_level,
               a.command,
               TRUNC((SYSDATE - d.start_date) * 86400) AS tx_sec,
               p.bs
          FROM gv$session a
          LEFT JOIN gv$process b
            ON a.inst_id = b.inst_id
           AND a.paddr = b.thread_addr
          LEFT JOIN v$sqlcommand c
            ON a.command = c.command_type
          JOIN gv$transaction d
            ON a.inst_id = d.inst_id
           AND a.sid = d.sid
           AND a.xid = d.xid
         CROSS JOIN (
                SELECT CASE
                         WHEN UPPER(value) = '8K' THEN 8192
                         WHEN UPPER(value) = '16K' THEN 16384
                         WHEN UPPER(value) = '32K' THEN 32768
                         ELSE TO_NUMBER(value)
                       END AS bs
                  FROM v$parameter
                 WHERE name = 'DB_BLOCK_SIZE'
               ) p
         WHERE a.type != 'BACKGROUND'
           AND (
                 NULLIF(TRIM('&&sid'), '') IS NULL
                 OR a.sid = TO_NUMBER(TRIM('&&sid'))
               )
         ORDER BY tx_sec DESC, used_ublk DESC
       ) b;
