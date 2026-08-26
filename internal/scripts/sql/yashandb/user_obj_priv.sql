-- File Name: user_obj_priv.sql
-- Purpose: Show object privileges for a user (direct and via roles)
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/user_obj_priv.sql


col grantee   for a20
col owner     for a15
col table_name for a25
col privilege for a15
col grantable for a5
col via       for a20

ACCEPT grantee_username PROMPT 'Enter grantee username (e.g. HTZ_PRIV): '
ACCEPT objectname PROMPT 'Enter object name (empty=all): '

PROMPT ===== Table/object privileges (dba_tab_privs) =====
SELECT a.grantee,
       a.owner,
       a.table_name,
       a.privilege,
       a.grantable,
       CASE
         WHEN a.grantee = UPPER(TRIM('&&grantee_username')) THEN 'direct'
         ELSE a.grantee
       END AS via
  FROM dba_tab_privs a
 WHERE (
         a.grantee = UPPER(TRIM('&&grantee_username'))
         OR a.grantee IN (
              SELECT DISTINCT granted_role
                FROM dba_role_privs
               START WITH grantee = UPPER(TRIM('&&grantee_username'))
             CONNECT BY PRIOR granted_role = grantee
            )
       )
   AND a.table_name = NVL(NULLIF(UPPER(TRIM('&&objectname')), ''), a.table_name)
 ORDER BY via, owner, table_name, privilege;
