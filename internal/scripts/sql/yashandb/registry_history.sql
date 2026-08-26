-- File Name: registry_history.sql
-- Purpose: YashanDB Show bootstrap and patch history from DBA_REGISTRY_HISTORY
-- Supported: 23.5
-- Created: 20260822 by huangtingzhong
-- Usage: days_back = how many days to look back (empty=3650, effectively all)

PROMPT Enter days back (empty=all):

col action_time   for a26
col action        for a14
col namespace     for a12
col version       for a18
col id            for a10
col comments      for a36
col bundle_series for a24

SELECT TO_CHAR(action_time, 'YYYY-MM-DD HH24:MI:SS') AS action_time,
       action,
       namespace,
       version,
       id || '' AS id,
       SUBSTR(comments, 1, 36) AS comments,
       SUBSTR(bundle_series, 1, 24) AS bundle_series
  FROM dba_registry_history
 WHERE action_time >= SYSDATE
       - (NVL(TO_NUMBER(NULLIF(TRIM('&days_back'), '')), 3650) / 24)
 ORDER BY action_time DESC;
