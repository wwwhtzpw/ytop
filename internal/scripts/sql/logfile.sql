select THREAD#,ID||'' groupid,NAME,trunc(BLOCK_SIZE*BLOCK_COUNT/1024/1024) size_m,status,type,SEQUENCE# from v$logfile;
