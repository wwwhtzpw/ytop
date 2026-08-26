-- File Name: object_dependency.sql
-- Purpose: Show direct referenced objects for a given object
-- Created: 20260801 by huangtingzhong
--
-- Params: &&owner, &&object_name (empty=match all for that filter)
-- Source view: DBA_DEPENDENCIES + DBA_OBJECTS


col owner_name      for a40
col referenced_type for a15
col last_ddl        for a19
col status          for a10
col dependency_type for a10

ACCEPT owner PROMPT 'Enter owner (empty=all): '
ACCEPT object_name PROMPT 'Enter object name (empty=all): '

SELECT a.referenced_owner || '.' || a.referenced_name AS owner_name,
       a.referenced_type,
       TO_CHAR(b.last_ddl_time, 'yyyy-mm-dd hh24:mi:ss') AS last_ddl,
       b.status,
       a.dependency_type
  FROM dba_dependencies a, dba_objects b
 WHERE a.referenced_owner = b.owner
   AND a.referenced_name = b.object_name
   AND a.referenced_type = b.object_type
   AND a.owner = NVL(NULLIF(UPPER(TRIM('&&owner')), ''), a.owner)
   AND a.name = NVL(NULLIF(UPPER(TRIM('&&object_name')), ''), a.name)
 ORDER BY a.referenced_type, owner_name;
