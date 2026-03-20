col dest_name for a16
col CONNECTION               for a16
col PEER_ADDR                for a20
col status                   for a15
col DATABASE_MODE            for a10
col RECEIVED_LFN             for a10
col RECEIVED_LFN             for a10
col GAP_STATUS               for a10
col DISCONNECT_TIME          for a15
col RECEIVED_SCN             for a15
col DB_UNIQUE_NAME           for a15

select DEST_NAME,DB_UNIQUE_NAME,PEER_ADDR,CONNECTION,STATUS,DATABASE_MODE,SYNCHRONIZED,GAP_STATUS,DISCONNECT_TIME,RECEIVED_SCN,APPLIED_LFN,FLUSH_LFN from v$archive_dest_status;
