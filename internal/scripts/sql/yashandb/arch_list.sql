-- File Name: arch_list.sql
-- Purpose: YashanDB List archived redo files in a time window
-- Created: 20260612  by  huangtingzhong
-- Usage: &hours_back = oldest boundary (hours ago, default 24);
--        &interval_hours = window length toward now (default 1; 0 = from hours_back to now)
-- Numeric &vars use quoted NVL/TO_NUMBER so empty input is safe for ytop and yasql.

col thread#          for a8
col sequence#        for a10
col archive_path     for a64
col first_time       for a26
col completion_time  for a26
col hours_ago        for a12

SELECT thread# || '' AS thread#,
       sequence# || '' AS sequence#,
       name AS archive_path,
       first_time,
       completion_time,
       ROUND((SYSDATE - CAST(completion_time AS DATE)) * 24, 2) || '' AS hours_ago
  FROM v$archived_log
 WHERE completion_time >= SYSDATE
       - (NVL(TO_NUMBER(NULLIF(TRIM('&hours_back'), '')), 24) / 24)
   AND completion_time <= SYSDATE
       - ((NVL(TO_NUMBER(NULLIF(TRIM('&hours_back'), '')), 24)
           - NVL(TO_NUMBER(NULLIF(TRIM('&interval_hours'), '')), 1)) / 24)
 ORDER BY completion_time DESC;
