-- File Name: object_invalid.sql
-- Purpose: List invalid objects and packages missing body
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/object_invalid.sql


col own    for a15
col name   for a40
col type   for a18
col status for a10
col prob   for a14

ACCEPT owner PROMPT 'Enter owner (empty=non-SYS/SYSTEM): '

SELECT a.owner AS own,
       a.object_name AS name,
       a.object_type AS type,
       a.status,
       'Miss Pkg Body' AS prob
  FROM dba_objects a
 WHERE a.object_type = 'PACKAGE'
   AND a.owner = NVL(NULLIF(UPPER(TRIM('&&owner')), ''), a.owner)
   AND a.owner NOT IN ('SYS', 'SYSTEM')
   AND NOT EXISTS (
         SELECT 1
           FROM dba_objects b
          WHERE b.object_name = a.object_name
            AND b.owner = a.owner
            AND b.object_type = 'PACKAGE BODY'
       )
UNION ALL
SELECT owner AS own,
       object_name AS name,
       object_type AS type,
       status,
       'Invalid Obj' AS prob
  FROM dba_objects
 WHERE status != 'VALID'
   AND owner = NVL(NULLIF(UPPER(TRIM('&&owner')), ''), owner)
   AND owner NOT IN ('SYS', 'SYSTEM')
 ORDER BY own, status, type, name;
