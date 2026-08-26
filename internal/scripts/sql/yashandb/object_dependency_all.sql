-- File Name: object_dependency_all.sql
-- Purpose: Show recursive forward dependency tree via CONNECT BY
-- Created: 20260801 by huangtingzhong
--
-- Params: &&owner, &&objectname (required)
-- Note: CONNECT BY matches owner+name only (same as Oracle script)


col lv              for a4
col o_n             for a40
col type            for a15
col r_o_n           for a40
col referenced_type for a15
col status          for a10
col created         for a19
col last_ddl        for a19

ACCEPT owner PROMPT 'Enter owner (e.g. SYS): '
ACCEPT objectname PROMPT 'Enter object name (e.g. DBA_ALL_TABLES): '

SELECT TO_CHAR(c.lv) AS lv,
       c.owner || '.' || c.name AS o_n,
       c.type,
       c.referenced_owner || '.' || c.referenced_name AS r_o_n,
       c.referenced_type,
       d.status,
       TO_CHAR(d.created, 'yyyy-mm-dd hh24:mi:ss') AS created,
       TO_CHAR(d.last_ddl_time, 'yyyy-mm-dd hh24:mi:ss') AS last_ddl
  FROM (
        SELECT a.owner,
               a.name,
               a.type,
               a.referenced_owner,
               a.referenced_name,
               a.referenced_type,
               LEVEL AS lv
          FROM dba_dependencies a
         START WITH a.owner = UPPER(TRIM('&&owner'))
                AND a.name = UPPER(TRIM('&&objectname'))
        CONNECT BY NOCYCLE a.owner = PRIOR a.referenced_owner
               AND a.name = PRIOR a.referenced_name
       ) c,
       dba_objects d
 WHERE c.owner = d.owner
   AND c.name = d.object_name
   AND c.type = d.object_type
 ORDER BY c.lv, o_n, r_o_n;
