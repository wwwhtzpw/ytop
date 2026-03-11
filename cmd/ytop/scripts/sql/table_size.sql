col owner          for  a20
col table_name     for  a25
col count_max_sum  for  a15
col TOTAL_SIZE     for  a10
col TABLE_SIZE     for  a10
col LOB_SIZE       for  a10
col INDEX_SIZE     for  a10

WITH d AS (
    SELECT table_owner, table_name,
           COUNT(*) || ':' || MAX(subpartition_count) || ':' || SUM(subpartition_count) AS count_max_sum
    FROM dba_tab_partitions
    WHERE table_owner = NVL(UPPER('&&owner'), table_owner)
      AND table_name  = NVL(UPPER('&&tablename'), table_name)
    GROUP BY table_owner, table_name
),
-- 仅收集指定表的段：与 CTE 版逻辑一致，避免与 d 笛卡尔积
c AS (
    SELECT c.owner, c.table_name, a.segment_type, a.bytes
    FROM dba_segments a
    JOIN dba_lobs b ON a.segment_name = b.segment_name AND a.owner = b.owner
    JOIN dba_tables c ON b.owner = c.owner AND b.table_name = c.table_name
    WHERE c.owner = NVL(UPPER('&&owner'), c.owner)
      AND c.table_name = NVL(UPPER('&&tablename'), c.table_name)
    UNION ALL
    SELECT c.owner, c.table_name, a.segment_type, a.bytes
    FROM dba_segments a
    JOIN dba_indexes b ON a.segment_name = b.index_name AND a.owner = b.owner
    JOIN dba_tables c ON b.table_owner = c.owner AND b.table_name = c.table_name
    WHERE c.owner = NVL(UPPER('&&owner'), c.owner)
      AND c.table_name = NVL(UPPER('&&tablename'), c.table_name)
    UNION ALL
    SELECT a.owner, b.table_name, a.segment_type, a.bytes
    FROM dba_segments a
    JOIN dba_tables b ON a.owner = b.owner AND a.segment_name = b.table_name
    WHERE b.owner = NVL(UPPER('&&owner'), b.owner)
      AND b.table_name = NVL(UPPER('&&tablename'), b.table_name)
),
agg AS (
    SELECT c.owner, c.table_name,
           SUM(c.bytes) AS t_size,
           SUM(CASE WHEN c.segment_type IN ('TABLE', 'TABLE PARTITION') THEN c.bytes END) AS table_size,
           SUM(CASE WHEN c.segment_type LIKE 'LOB%'   THEN c.bytes END) AS lob_size,
           SUM(CASE WHEN c.segment_type LIKE 'INDEX%' THEN c.bytes END) AS index_size
    FROM c
    GROUP BY c.owner, c.table_name
    ORDER BY t_size
)
SELECT agg.owner, agg.table_name, trunc(agg.t_size/1024/1024)||'M'  AS total_size,
       d.count_max_sum,
       trunc(agg.table_size/1024/1024)||'M' table_size, trunc(agg.lob_size/1024/1024)||'M' lob_size, trunc(agg.index_size/1024/1024)||'M' index_size
  FROM agg
  LEFT JOIN d ON d.table_owner = agg.owner AND d.table_name = agg.table_name
 WHERE agg.owner = NVL(UPPER('&&owner'), agg.owner)
   AND agg.table_name = NVL(UPPER('&&tablename'), agg.table_name);
