-- File Name: constraint_table.sql
-- Purpose: YashanDB List table constraints and referenced
-- Created: 20250307  by  huangtingzhong

-- Params: &&owner (default all), &&tablename (default all)
COL owner_name  FOR A64
COL name        FOR A64
COL column_name FOR A32
COL type        FOR A24
COL status      FOR A16
COL ref_tab     FOR A64
COL ref_con     FOR A64
COL index_name  FOR A64

SELECT DISTINCT a.owner || ':' || a.table_name AS owner_name,
       a.constraint_name AS name,
       c.column_name,
       DECODE(a.constraint_type,
              'C', 'Check or Not null',
              'R', 'Foreign Key',
              'P', 'Primary key',
              'U', 'Unique',
              '*') AS type,
       a.status,
       b.owner || '.' || b.table_name AS ref_tab,
       a.r_constraint_name AS ref_con,
       a.index_name
  FROM dba_constraints a
  LEFT JOIN dba_constraints b ON a.r_owner = b.owner AND a.r_constraint_name = b.constraint_name
  JOIN dba_cons_columns c ON a.owner = c.owner AND a.constraint_name = c.constraint_name AND a.table_name = c.table_name
 WHERE a.owner = NVL(UPPER(TRIM('&&owner')), a.owner)
   AND a.table_name = NVL(UPPER(TRIM('&&tablename')), a.table_name)
UNION ALL
SELECT DISTINCT a.owner || ':' || a.table_name AS owner_name,
       a.constraint_name AS name,
       c.column_name,
       DECODE(a.constraint_type,
              'C', 'Check or Not null',
              'R', 'Foreign Key',
              'P', 'Primary key',
              'U', 'Unique',
              '*') AS type,
       a.status,
       b.owner || '.' || b.table_name AS ref_tab,
       a.r_constraint_name AS ref_con,
       a.index_name
  FROM dba_constraints a
  LEFT JOIN dba_constraints b ON a.r_owner = b.owner AND a.r_constraint_name = b.constraint_name
  JOIN dba_cons_columns c ON a.owner = c.owner AND a.constraint_name = c.constraint_name AND a.table_name = c.table_name
 WHERE b.owner = NVL(UPPER(TRIM('&&owner')), b.owner)
   AND b.table_name = NVL(UPPER(TRIM('&&tablename')), b.table_name)
 ORDER BY 1
/
