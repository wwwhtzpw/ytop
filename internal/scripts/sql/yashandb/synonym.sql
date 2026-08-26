-- File Name: synonym.sql
-- Purpose: List synonyms and their targets
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/synonym.sql


col owner_name  for a40
col target_name for a40
col db_link     for a25
col created     for a19

ACCEPT owner PROMPT 'Enter synonym owner (empty=all): '
ACCEPT synonym_name PROMPT 'Enter synonym name (empty=all): '

SELECT a.owner || '.' || a.synonym_name AS owner_name,
       a.table_owner || '.' || a.table_name AS target_name,
       a.db_link,
       TO_CHAR(b.created, 'yyyy-mm-dd hh24:mi:ss') AS created
  FROM dba_synonyms a, dba_objects b
 WHERE a.owner = b.owner(+)
   AND a.synonym_name = b.object_name(+)
   AND b.object_type(+) = 'SYNONYM'
   AND a.owner = NVL(NULLIF(UPPER(TRIM('&&owner')), ''), a.owner)
   AND a.synonym_name = NVL(NULLIF(UPPER(TRIM('&&synonym_name')), ''), a.synonym_name)
 ORDER BY a.owner, a.synonym_name;
