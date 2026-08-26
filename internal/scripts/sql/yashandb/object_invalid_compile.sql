-- File Name: object_invalid_compile.sql
-- Purpose: Generate ALTER COMPILE DDL for invalid PL/SQL objects
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/object_invalid_compile.sql
-- Note: YashanDB does not support ALTER VIEW ... COMPILE; VIEW rows are listed as comments only


col compile_ddl for a120

ACCEPT owner PROMPT 'Enter owner (empty=all owners): '

SELECT CASE
         WHEN object_type = 'VIEW' THEN
           '-- VIEW compile unsupported; recreate manually: '
           || owner || '.' || object_name
         WHEN object_type = 'PACKAGE BODY' THEN
           'ALTER PACKAGE ' || owner || '.' || object_name || ' COMPILE BODY;'
         WHEN object_type = 'PACKAGE' THEN
           'ALTER PACKAGE ' || owner || '.' || object_name || ' COMPILE;'
         ELSE
           'ALTER ' || object_type || ' ' || owner || '.' || object_name || ' COMPILE;'
       END AS compile_ddl
  FROM dba_objects
 WHERE status = 'INVALID'
   AND object_type IN (
         'PACKAGE BODY', 'PACKAGE', 'FUNCTION', 'PROCEDURE', 'TRIGGER', 'VIEW'
       )
   AND owner = NVL(NULLIF(UPPER(TRIM('&&owner')), ''), owner)
 ORDER BY
       CASE object_type
         WHEN 'VIEW' THEN 9
         ELSE 1
       END,
       object_type,
       owner,
       object_name;
