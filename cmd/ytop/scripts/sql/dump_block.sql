-- File Name:dump_block.sql
-- Purpose: dump block and get trace file name
-- Created: 20251201  by  huangtingzhong

alter system dump datafile &datafile minblock &minblock  maxblock &maxblock;
SELECT value||'/'||SYS_CONTEXT('USERENV', 'DB_NAME')||'_'||to_char(sysdate,'yyyymmdd')||'_'||SYS_CONTEXT('USERENV', 'SID')||'.trc' from v$parameter where name='DIAGNOSTIC_DEST';
