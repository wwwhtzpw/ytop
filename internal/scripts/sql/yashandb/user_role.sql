-- File Name: user_role.sql
-- Purpose: Show roles granted to a user (recursive)
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/user_role.sql


col grantee      for a25
col granted_role for a30
col admin_option for a6
col lv           for a4

ACCEPT username PROMPT 'Enter username (e.g. HTZ_PRIV): '

SELECT DISTINCT grantee,
       granted_role,
       admin_option,
       TO_CHAR(LEVEL) AS lv
  FROM dba_role_privs
 START WITH grantee = UPPER(TRIM('&&username'))
CONNECT BY PRIOR granted_role = grantee
 ORDER BY lv, grantee, granted_role;
