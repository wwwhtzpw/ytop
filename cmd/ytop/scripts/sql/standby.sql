col peer_addr for a25
select * from v$recovery_status;
SELECT connection,status,peer_addr,peer_point,received_point,applied_point,transport_lag,apply_lag,GAP_SEQ#,TIME_SINCE_LAST_MSG FROM GV$REPLICATION_STATUS;
SELECT item,units,value FROM GV$RECOVERY_PROGRESS;
