-- File Name : get_ddl_table.sql
-- Purpose : display ddl about table index trigger，must input table owner and table_name
-- Created : 20251201  by  huangtingzhong

SELECT DBMS_METADATA.GET_DDL ('TABLE', OBJECT_NAME, OWNER)
  FROM Dba_objects
 WHERE     owner = UPPER ('&TABLE_OWNER')
       AND object_name = UPPER ('&TABLE_NAME')
       AND object_type = 'TABLE'
union all
SELECT DBMS_METADATA.GET_DDL ('INDEX', INDEX_NAME, owner)
  FROM (SELECT INDEX_NAME, owner
          FROM Dba_indexes
         WHERE     table_owner = UPPER ('&TABLE_OWNER')
       AND table_name = UPPER ('&TABLE_NAME')
               AND index_name NOT IN
                      (SELECT constraint_name
                         FROM sys.Dba_constraints
                        WHERE     table_name = table_name
                              AND constraint_type = 'P'))
union all
SELECT DBMS_METADATA.GET_DDL ('TRIGGER', trigger_name, owner)
  FROM Dba_triggers
 WHERE    table_owner = UPPER ('&TABLE_OWNER')
       AND table_name = UPPER ('&TABLE_NAME')
/
