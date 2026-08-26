-- File Name: role.sql
-- Purpose: List database roles
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/role.sql


col role           for a40
col role_id        for a10
col type           for a12
col common         for a6
col sys_maintained for a6

ACCEPT role_name PROMPT 'Enter role name fragment (empty=all): '

SELECT role,
       TO_CHAR(role_id) AS role_id,
       type,
       common,
       sys_maintained
  FROM dba_roles
 WHERE (
         NULLIF(UPPER(TRIM('&&role_name')), '') IS NULL
         OR UPPER(role) LIKE '%' || UPPER(TRIM('&&role_name')) || '%'
       )
 ORDER BY role;
