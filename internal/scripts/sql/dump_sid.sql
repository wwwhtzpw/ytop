alter system dump session &sid backtrace;
SELECT value||'/'||SYS_CONTEXT('USERENV', 'DB_NAME')||'_'||to_char(sysdate,'yyyymmdd')||'_'||SYS_CONTEXT('USERENV', 'SID')||'.trc' from v$parameter where name='DIAGNOSTIC_DEST';
