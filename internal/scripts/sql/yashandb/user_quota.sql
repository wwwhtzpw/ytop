-- File Name: user_quota.sql
-- Purpose: Show tablespace quotas and UNLIMITED TABLESPACE grants
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/user_quota.sql


col username        for a20
col tablespace_name for a16
col used_mb         for a12
col max_mb          for a12
col privilege       for a30

ACCEPT username PROMPT 'Enter username (empty=all): '

PROMPT ===== dba_ts_quotas =====
SELECT username,
       tablespace_name,
       TO_CHAR(ROUND(bytes / 1024 / 1024, 2)) AS used_mb,
       CASE
         WHEN max_bytes = -1 THEN 'UNLIMITED'
         ELSE TO_CHAR(ROUND(max_bytes / 1024 / 1024, 2))
       END AS max_mb
  FROM dba_ts_quotas
 WHERE username = NVL(NULLIF(UPPER(TRIM('&&username')), ''), username)
 ORDER BY tablespace_name, username;

PROMPT ===== UNLIMITED TABLESPACE / unlimited quota =====
SELECT username,
       tablespace_name,
       privilege
  FROM (
        SELECT p1.grantee AS username,
               'Any Tablespace' AS tablespace_name,
               p1.privilege
          FROM dba_sys_privs p1
         WHERE p1.privilege = 'UNLIMITED TABLESPACE'
        UNION ALL
        SELECT r.grantee AS username,
               'Any Tablespace' AS tablespace_name,
               'via ' || r.granted_role AS privilege
          FROM dba_role_privs r
         WHERE r.granted_role IN (
                 SELECT grantee
                   FROM dba_sys_privs
                  WHERE privilege = 'UNLIMITED TABLESPACE'
               )
        UNION ALL
        SELECT username,
               tablespace_name,
               'DBA_TS_QUOTA UNLIMITED' AS privilege
          FROM dba_ts_quotas
         WHERE max_bytes = -1
       )
 WHERE username = NVL(NULLIF(UPPER(TRIM('&&username')), ''), username)
 ORDER BY username, tablespace_name;
