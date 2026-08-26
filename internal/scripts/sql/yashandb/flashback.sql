-- File Name: flashback.sql
-- Purpose: Collect database flashback status and logs
-- Supported: 23.4
-- Created: 20260706  by  huangtingzhong
-- Updated: 20260809 by huangtingzhong (renamed from flashback_info.sql)
--
-- Sections: summary, database status, flashback window, params,
--           log files, restore points, recyclebin, UNDO.
-- Ref: V$FLASHBACK_DATABASE_LOG, V$FLASHBACK_DATABASE_LOGFILE,
--      V$RESTORE_POINT, DB_FLASHBACK_* parameters (YashanDB 23.4+ doc).

SET SERVEROUTPUT OFF
SET VERIFY OFF
SET FEEDBACK OFF

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Flashback information report                                           |
PROMPT +------------------------------------------------------------------------+
PROMPT

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | 0. Summary (at a glance)                                               |
PROMPT +------------------------------------------------------------------------+
PROMPT

col flash_on     for a5
col log_mode     for a10
col oldest_time  for a26
col covered      for a12
col retention    for a14
col log_used     for a10
col log_limit    for a8
col log_pct      for a8
col undo_ret     for a8
col recyclebin   for a8

WITH prm AS (
  SELECT MAX(CASE WHEN UPPER(name) = 'DB_FLASHBACK_FILE_DEST_SIZE'
                  THEN value END) AS dest_size_raw,
         MAX(CASE WHEN UPPER(name) = 'DB_FLASHBACK_RETENTION_TARGET'
                  THEN TO_NUMBER(value) END) AS retention_min,
         MAX(CASE WHEN UPPER(name) = 'UNDO_RETENTION'
                  THEN value END) AS undo_retention,
         MAX(CASE WHEN UPPER(name) = 'RECYCLEBIN_ENABLED'
                  THEN value END) AS recyclebin_enabled
    FROM v$parameter
   WHERE UPPER(name) IN (
           'DB_FLASHBACK_FILE_DEST_SIZE',
           'DB_FLASHBACK_RETENTION_TARGET',
           'UNDO_RETENTION',
           'RECYCLEBIN_ENABLED'
         )
),
fb AS (
  SELECT MIN(g.oldest_flashback_time) AS oldest_time,
         MAX(g.total_file_size)       AS total_bytes,
         MAX(g.retention_target)      AS view_retention_min
    FROM gv$flashback_database_log g
),
dest_bytes AS (
  SELECT p.dest_size_raw,
         CASE
           WHEN UPPER(p.dest_size_raw) LIKE '%T'
             THEN TO_NUMBER(REGEXP_REPLACE(UPPER(p.dest_size_raw), '[^0-9.]', ''))
                  * 1024 * 1024 * 1024 * 1024
           WHEN UPPER(p.dest_size_raw) LIKE '%G'
             THEN TO_NUMBER(REGEXP_REPLACE(UPPER(p.dest_size_raw), '[^0-9.]', ''))
                  * 1024 * 1024 * 1024
           WHEN UPPER(p.dest_size_raw) LIKE '%M'
             THEN TO_NUMBER(REGEXP_REPLACE(UPPER(p.dest_size_raw), '[^0-9.]', ''))
                  * 1024 * 1024
           WHEN UPPER(p.dest_size_raw) LIKE '%K'
             THEN TO_NUMBER(REGEXP_REPLACE(UPPER(p.dest_size_raw), '[^0-9.]', ''))
                  * 1024
           ELSE TO_NUMBER(REGEXP_REPLACE(p.dest_size_raw, '[^0-9.]', ''))
         END AS dest_bytes
    FROM prm p
)
SELECT d.flashback_on AS flash_on,
       d.log_mode,
       TO_CHAR(fb.oldest_time, 'YYYY-MM-DD HH24:MI:SS.FF6') AS oldest_time,
       CASE
         WHEN fb.oldest_time IS NULL THEN '-'
         ELSE TRUNC((SYSDATE - CAST(fb.oldest_time AS DATE)) * 24) || 'h '
              || TRUNC(MOD((SYSDATE - CAST(fb.oldest_time AS DATE)) * 1440, 60)) || 'm'
       END AS covered,
       TO_CHAR(NVL(p.retention_min, fb.view_retention_min)) || 'm ('
         || TO_CHAR(TRUNC(NVL(p.retention_min, fb.view_retention_min) / 60)) || 'h)' AS retention,
       CASE
         WHEN fb.total_bytes IS NULL THEN '-'
         WHEN fb.total_bytes >= 1073741824
           THEN TO_CHAR(ROUND(fb.total_bytes / 1073741824, 2)) || ' GB'
         WHEN fb.total_bytes >= 1048576
           THEN TO_CHAR(ROUND(fb.total_bytes / 1048576, 1)) || ' MB'
         ELSE TO_CHAR(fb.total_bytes) || ' B'
       END AS log_used,
       p.dest_size_raw AS log_limit,
       CASE
         WHEN fb.total_bytes IS NULL OR db.dest_bytes IS NULL OR db.dest_bytes = 0 THEN '-'
         ELSE TO_CHAR(ROUND(fb.total_bytes * 100 / db.dest_bytes, 2)) || '%'
       END AS log_pct,
       p.undo_retention || 's' AS undo_ret,
       p.recyclebin_enabled AS recyclebin
  FROM v$database d
 CROSS JOIN fb
 CROSS JOIN prm p
 CROSS JOIN dest_bytes db;

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | 1. Database status (V$DATABASE)                                       |
PROMPT +------------------------------------------------------------------------+
PROMPT

col host_name      for a20
col db_name        for a15
col open_mode      for a12
col flashback_on   for a12
col db_role        for a15
col curr_scn       for a22
col db_time        for a26

SELECT d.host_name,
       d.database_name AS db_name,
       d.log_mode,
       d.open_mode,
       d.flashback_on,
       d.database_role AS db_role,
       TO_CHAR(d.current_scn) AS curr_scn,
       TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF6') AS db_time
  FROM v$database d;

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | 2. Flashback window (GV$FLASHBACK_DATABASE_LOG)                        |
PROMPT |    Earliest SCN/TIME = limit for FLASHBACK DATABASE TO TIME/SCN        |
PROMPT +------------------------------------------------------------------------+
PROMPT

col i                for a4
col oldest_scn       for a22
col oldest_time      for a26
col retention_min    for a10
col retention_h      for a10
col total_size       for a12
col oldest_age       for a12

SELECT TO_CHAR(g.inst_id) AS i,
       TO_CHAR(g.oldest_flashback_scn) AS oldest_scn,
       TO_CHAR(g.oldest_flashback_time, 'YYYY-MM-DD HH24:MI:SS.FF6') AS oldest_time,
       TO_CHAR(g.retention_target) AS retention_min,
       TO_CHAR(ROUND(g.retention_target / 60, 1)) AS retention_h,
       CASE
         WHEN g.total_file_size >= 1073741824
           THEN TO_CHAR(ROUND(g.total_file_size / 1073741824, 2)) || ' GB'
         WHEN g.total_file_size >= 1048576
           THEN TO_CHAR(ROUND(g.total_file_size / 1048576, 1)) || ' MB'
         ELSE TO_CHAR(g.total_file_size) || ' B'
       END AS total_size,
       TRUNC((SYSDATE - CAST(g.oldest_flashback_time AS DATE)) * 24) || 'h '
         || TRUNC(MOD((SYSDATE - CAST(g.oldest_flashback_time AS DATE)) * 1440, 60)) || 'm'
         AS oldest_age
  FROM gv$flashback_database_log g
 ORDER BY g.inst_id;

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | 3. Configuration parameters                                            |
PROMPT +------------------------------------------------------------------------+
PROMPT

col pname   for a32
col pvalue  for a40
col pdef    for a40
col pnote   for a36

SELECT p.name AS pname,
       p.value AS pvalue,
       p.default_value AS pdef,
       CASE UPPER(p.name)
         WHEN 'DB_FLASHBACK_RETENTION_TARGET' THEN 'minutes; logs older may be purged'
         WHEN 'DB_FLASHBACK_FILE_DEST_SIZE'   THEN 'max flashback log area'
         WHEN 'DB_FLASHBACK_FILE_DEST'        THEN 'flashback log directory'
         WHEN 'UNDO_RETENTION'              THEN 'sec; AS OF TIMESTAMP window'
         WHEN 'RECYCLEBIN_ENABLED'          THEN 'FLASHBACK TABLE BEFORE DROP'
         ELSE ''
       END AS pnote
  FROM (
        SELECT name, value, default_value, inst_id
          FROM gv_$parameter
        UNION ALL
        SELECT name, value, default_value, inst_id
          FROM gx_$parameter
       ) p
 WHERE UPPER(p.name) IN (
         'DB_FLASHBACK_FILE_DEST',
         'DB_FLASHBACK_FILE_DEST_SIZE',
         'DB_FLASHBACK_RETENTION_TARGET',
         'UNDO_RETENTION',
         'RECYCLEBIN_ENABLED'
       )
    OR UPPER(p.name) LIKE '%FLASHBACK%'
 ORDER BY p.inst_id, p.name;

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | 4. Flashback log files (GV$FLASHBACK_DATABASE_LOGFILE)                 |
PROMPT +------------------------------------------------------------------------+
PROMPT

col file_short  for a28
col file_path   for a55
col thread_num  for a3
col seq_num     for a6
col file_size   for a10
col first_scn   for a22
col first_time  for a26

SELECT REGEXP_SUBSTR(g.file_name, '[^/]+$') AS file_short,
       g.file_name AS file_path,
       TO_CHAR(g.thread#) AS thread_num,
       TO_CHAR(g.sequence#) AS seq_num,
       CASE
         WHEN g.file_size >= 1048576
           THEN TO_CHAR(ROUND(g.file_size / 1048576, 1)) || ' MB'
         ELSE TO_CHAR(g.file_size) || ' B'
       END AS file_size,
       TO_CHAR(g.first_change#) AS first_scn,
       TO_CHAR(g.first_time, 'YYYY-MM-DD HH24:MI:SS.FF6') AS first_time
  FROM gv$flashback_database_logfile g
 ORDER BY g.inst_id, g.sequence#, g.file_num;

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | 5. Restore points (V$RESTORE_POINT)                                    |
PROMPT |    (no rows = no restore points defined)                               |
PROMPT +------------------------------------------------------------------------+
PROMPT

col rp_name    for a32
col rp_scn     for a22
col guarantee  for a9
col rp_time    for a26

SELECT r.name AS rp_name,
       TO_CHAR(r.scn) AS rp_scn,
       CASE WHEN r.is_guarantee = 1 THEN 'YES' ELSE 'NO' END AS guarantee,
       TO_CHAR(r.create_time, 'YYYY-MM-DD HH24:MI:SS.FF6') AS rp_time
  FROM v$restore_point r
 ORDER BY r.create_time DESC;

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | 6. Recyclebin (FLASHBACK TABLE ... BEFORE DROP/TRUNCATE)               |
PROMPT +------------------------------------------------------------------------+
PROMPT

col rb_count for a12

SELECT TO_CHAR(COUNT(*)) AS rb_count
  FROM dba_recyclebin;

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | 7. UNDO tablespace (AS OF TIMESTAMP / flashback query)                 |
PROMPT +------------------------------------------------------------------------+
PROMPT

col undo_ts     for a12
col undo_size   for a10
col undo_used   for a10
col undo_free   for a10
col undo_pct    for a7

SELECT x.tablespace_name AS undo_ts,
       TO_CHAR(TRUNC(x.total_bytes / 1048576)) || ' MB' AS undo_size,
       TO_CHAR(TRUNC(x.used_bytes / 1048576)) || ' MB' AS undo_used,
       TO_CHAR(TRUNC(x.free_bytes / 1048576)) || ' MB' AS undo_free,
       TO_CHAR(ROUND(x.used_bytes * 100 / NULLIF(x.total_bytes, 0), 1)) || '%' AS undo_pct
  FROM (
        SELECT df.tablespace_name,
               SUM(df.bytes) AS total_bytes,
               SUM(df.bytes) - NVL(SUM(fs.bytes), 0) AS used_bytes,
               NVL(SUM(fs.bytes), 0) AS free_bytes
          FROM dba_data_files df
          JOIN dba_tablespaces ts
            ON ts.tablespace_name = df.tablespace_name
           AND ts.contents = 'UNDO'
          LEFT JOIN dba_free_space fs
            ON fs.tablespace_name = df.tablespace_name
         GROUP BY df.tablespace_name
       ) x
 ORDER BY x.tablespace_name;

PROMPT
PROMPT --- End of flashback report ---
