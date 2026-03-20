-- File Name: partition_size_with_lob.sql
-- Purpose: Show table partition and subpartition sizes including LOB by owner and table name
-- Created: 20260307  by  oracle-to-yashandb
-- Params: &&owner (default all), &&table_name (default all)

UNDEFINE owner;
UNDEFINE table_name;

COL owner       FOR A30
COL table_name  FOR A30
COL part_name   FOR A35
COL subpart_name FOR A35
COL part_size   FOR A20
COL subpart_size FOR A20
COL lob_size    FOR A20
COL sublob_size FOR A20

WITH
part_only AS (
    SELECT p.table_owner    AS owner,
           p.table_name    AS table_name,
           p.partition_name AS part_name,
           CAST(NULL AS VARCHAR(128)) AS subpart_name,
           p.partition_position       AS part_pos,
           0                          AS subpart_pos
      FROM dba_tab_partitions p
     WHERE p.table_owner = NVL(UPPER('&&owner'), p.table_owner)
       AND p.table_name  = NVL(UPPER('&&table_name'), p.table_name)
       AND (p.subpartition_count = 0 OR p.subpartition_count IS NULL)
       AND NOT EXISTS (
             SELECT 1 FROM dba_tab_subpartitions sp
              WHERE sp.table_owner = p.table_owner
                AND sp.table_name  = p.table_name
                AND sp.partition_name = p.partition_name
           )
),
subpart_only AS (
    SELECT sp.table_owner       AS owner,
           sp.table_name        AS table_name,
           sp.partition_name    AS part_name,
           sp.subpartition_name AS subpart_name,
           sp.partition_position AS part_pos,
           sp.subpartition_position AS subpart_pos
      FROM dba_tab_subpartitions sp
     WHERE sp.table_owner = NVL(UPPER('&&owner'), sp.table_owner)
       AND sp.table_name  = NVL(UPPER('&&table_name'), sp.table_name)
),
base AS (
    SELECT owner, table_name, part_name, subpart_name, part_pos, subpart_pos FROM part_only
    UNION ALL
    SELECT owner, table_name, part_name, subpart_name, part_pos, subpart_pos FROM subpart_only
),
part_seg AS (
    SELECT b.owner, b.table_name, b.part_name, b.subpart_name,
           NVL(s.bytes, 0) AS part_size
      FROM base b
      LEFT JOIN dba_segments s
        ON s.owner = b.owner
       AND s.segment_name = b.table_name
       AND s.partition_name = b.part_name
       AND s.segment_type = 'TABLE PARTITION'
       AND b.subpart_name IS NULL
),
subpart_seg AS (
    SELECT b.owner, b.table_name, b.part_name, b.subpart_name,
           NVL(s.bytes, 0) AS subpart_size
      FROM base b
      LEFT JOIN dba_segments s
        ON s.owner = b.owner
       AND s.segment_name = b.table_name
       AND s.partition_name = b.subpart_name
       AND s.segment_type = 'TABLE SUBPARTITION'
       AND b.subpart_name IS NOT NULL
),
lob_part_seg AS (
    SELECT lp.table_owner AS owner, lp.table_name AS table_name, lp.partition_name AS part_name,
           SUM(s.bytes) AS lob_size
      FROM dba_lob_partitions lp
      JOIN dba_lobs l ON l.owner = lp.table_owner AND l.table_name = lp.table_name
      JOIN dba_segments s
        ON s.owner = lp.table_owner
       AND s.segment_name = l.segment_name
       AND s.partition_name = lp.lob_partition_name
       AND s.segment_type = 'LOB PARTITION'
     WHERE lp.table_owner = NVL(UPPER('&&owner'), lp.table_owner)
       AND lp.table_name  = NVL(UPPER('&&table_name'), lp.table_name)
     GROUP BY lp.table_owner, lp.table_name, lp.partition_name
),
lob_subpart_seg AS (
    SELECT lp.table_owner AS owner, lp.table_name AS table_name,
           lp.partition_name AS part_name, lsp.subpartition_name AS subpart_name,
           SUM(s.bytes) AS sublob_size
      FROM dba_lob_subpartitions lsp
      JOIN dba_lob_partitions lp
        ON lp.table_owner = lsp.table_owner AND lp.table_name = lsp.table_name
       AND lp.lob_partition_name = lsp.lob_partition_name
      JOIN dba_lobs l ON l.owner = lsp.table_owner AND l.table_name = lsp.table_name
      JOIN dba_segments s
        ON s.owner = lsp.table_owner
       AND s.segment_name = l.segment_name
       AND s.partition_name = lsp.lob_subpartition_name
       AND s.segment_type = 'LOB SUBPARTITION'
     WHERE lsp.table_owner = NVL(UPPER('&&owner'), lsp.table_owner)
       AND lsp.table_name  = NVL(UPPER('&&table_name'), lsp.table_name)
     GROUP BY lp.table_owner, lp.table_name, lp.partition_name, lsp.subpartition_name
),
result AS (
  SELECT b.owner,
         b.table_name,
         b.part_name,
         b.subpart_name,
         NVL(ps.part_size, 0)    AS part_size,
         NVL(ss.subpart_size, 0) AS subpart_size,
         NVL(lp.lob_size, 0)     AS lob_size,
         NVL(ls.sublob_size, 0)  AS sublob_size,
         b.part_pos,
         b.subpart_pos
    FROM base b
    LEFT JOIN part_seg ps
      ON ps.owner = b.owner AND ps.table_name = b.table_name AND ps.part_name = b.part_name
     AND b.subpart_name IS NULL
    LEFT JOIN subpart_seg ss
      ON ss.owner = b.owner AND ss.table_name = b.table_name
     AND ss.part_name = b.part_name AND ss.subpart_name = b.subpart_name
    LEFT JOIN lob_part_seg lp
      ON lp.owner = b.owner AND lp.table_name = b.table_name AND lp.part_name = b.part_name
    LEFT JOIN lob_subpart_seg ls
      ON ls.owner = b.owner AND ls.table_name = b.table_name
     AND ls.part_name = b.part_name AND ls.subpart_name = b.subpart_name
)
SELECT owner,
       table_name,
       part_name,
       subpart_name,
       TO_CHAR(part_size)    AS part_size,
       TO_CHAR(subpart_size) AS subpart_size,
       TO_CHAR(lob_size)     AS lob_size,
       TO_CHAR(sublob_size)  AS sublob_size
  FROM result
 ORDER BY part_pos, subpart_pos;
