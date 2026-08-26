-- File Name: user_sys_priv.sql
-- Purpose: Show system privileges granted directly or via roles
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/user_sys_priv.sql (rewritten for dba_sys_privs)


col privilege for a40
col via       for a30
col admin_option for a6

ACCEPT username PROMPT 'Enter username (e.g. HTZ_PRIV): '

SELECT privilege,
       'Granted directly' AS via,
       admin_option
  FROM dba_sys_privs
 WHERE grantee = UPPER(TRIM('&&username'))
UNION ALL
SELECT p.privilege,
       p.grantee AS via,
       p.admin_option
  FROM dba_sys_privs p
 WHERE p.grantee IN (
         SELECT granted_role
           FROM dba_role_privs
          START WITH grantee = UPPER(TRIM('&&username'))
        CONNECT BY PRIOR granted_role = grantee
       )
 ORDER BY privilege, via;
