-- File Name: sess_cursor.sql
-- Purpose: Show open cursor counts and v$open_cursor memory usage
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/sess_cursor.sql
-- Note: no CURSOR_TYPE / process SPID; uses OPENED CURSORS CURRENT + OPEN_CURSORS


col username   for a20
col sid        for a8
col sql_id     for a15
col cnt        for a8
col pmem       for a12
col gmem       for a12

ACCEPT username PROMPT 'Enter username (empty=all non-null): '

PROMPT ===== Open cursors grouped by session/sql_id (v$open_cursor) =====
SELECT oc.user_name AS username,
       TO_CHAR(oc.sid) AS sid,
       oc.sql_id,
       TO_CHAR(COUNT(*)) AS cnt,
       TO_CHAR(SUM(oc.pmem_used_size)) AS pmem,
       TO_CHAR(SUM(oc.gmem_used_size)) AS gmem
  FROM v$open_cursor oc
 WHERE oc.user_name = NVL(NULLIF(UPPER(TRIM('&&username')), ''), oc.user_name)
 GROUP BY oc.user_name, oc.sid, oc.sql_id
HAVING COUNT(*) >= 1
 ORDER BY COUNT(*) DESC, oc.user_name, oc.sid;

PROMPT ===== Session opened cursors current vs OPEN_CURSORS =====
col status for a10
col open_cursors for a12
col max_open_cur for a12
col open_pct for a8
SELECT TO_CHAR(s.sid) AS sid,
       s.username,
       s.status,
       TO_CHAR(st.value) AS open_cursors,
       p.value AS max_open_cur,
       TO_CHAR(
         CASE
           WHEN TO_NUMBER(p.value) = 0 THEN NULL
           ELSE ROUND(100 * st.value / TO_NUMBER(p.value), 1)
         END
       ) AS open_pct
  FROM v$session s,
       v$sesstat st,
       v$statname sn,
       v$parameter p
 WHERE s.sid = st.sid
   AND st.statistic# = sn.statistic#
   AND sn.name = 'OPENED CURSORS CURRENT'
   AND UPPER(p.name) = 'OPEN_CURSORS'
   AND s.username = NVL(NULLIF(UPPER(TRIM('&&username')), ''), s.username)
   AND s.username IS NOT NULL
 ORDER BY st.value DESC NULLS LAST, s.sid;
