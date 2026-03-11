-- File Name: parameter.sql
-- Purpose: show parameter value  information
-- Created: 20251208  by  huangtingzhong
col i              for a1
col name           for a30
col value          for a50
col IS_DEPRECATED  for a10

select inst_id||'' i,
name,value,default_value,
IS_DEPRECATED,ISPDB_MODIFIABLE PDB_MODIFY ,ISPDB_PRIVATE PDB_PRIVATE
 from (
 SELECT inst_id,name,value,default_value, IS_DEPRECATED,ISPDB_MODIFIABLE,ISPDB_PRIVATE FROM GV_$PARAMETER
 UNION 
 SELECT inst_id,name,value,default_value, IS_DEPRECATED,ISPDB_MODIFIABLE,ISPDB_PRIVATE FROM GX_$PARAMETER) a where (a.name LIKE  '%'||upper('&parameter')||'%') or (a.name=decode(upper('&parameter'),'',a.name) and a.default_value=a.value)
 order by inst_id,name;
