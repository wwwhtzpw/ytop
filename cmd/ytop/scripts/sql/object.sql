-- File Name:object.sql
-- Purpose: display object information based on  the input  text
-- Created: 20251201  by  huangtingzhong



set verify off
col createtime  for a20 
col ddtime      for a20 
col owner       for a20
col object_name for a40
col object_type for a15 
col status      for a10




SELECT owner,
         object_name,
         object_type,
         object_id,
         data_object_id,
         status,
         TO_CHAR (created, 'yyyy-mm-dd hh24:mi:ss') createtime,
         TO_CHAR (last_ddl_time, 'yyyy-mm-dd hh24:mi:ss') ddtime
    FROM sys.dba_objects
   WHERE object_name like '%'||upper('&objectname')||'%'
ORDER BY owner, object_type
/
