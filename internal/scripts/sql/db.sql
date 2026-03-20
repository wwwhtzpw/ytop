col database_name          for a15
col host_name              for a15
col PROTECTION_MODE        for a20
col PROTECTION_LEVEL       for a20
col SWITCHOVER_STATUS      for a20
col flashback_on           for a12
col status                 for a15
col log_mode               for a10
col open_mode              for a10

select host_name,DATABASE_NAME,log_mode,open_mode,status,flashback_on,DATABASE_ROLE,PROTECTION_MODE,PROTECTION_LEVEL,SWITCHOVER_STATUS from v$database;
