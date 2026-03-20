-- File Name:segment.sql
-- Purpose: display segment information
-- Created: 20260303  by  huangtingzhong
COLUMN owner_segment_name FORMAT A48
COLUMN partition_name     FORMAT A30
COLUMN tablespace         FORMAT A30
COLUMN header_file_block  FORMAT A15
COLUMN size              FORMAT A12

SELECT owner_segment_name,
       partition_name,
       tablespace,
       header_file_block,
       bytes||'M' size,
       blocks,
       extents
  FROM (
        SELECT owner || '.' || segment_name AS owner_segment_name,
               partition_name,
               segment_type,
               tablespace_name AS tablespace,
               header_file || '.' || header_block AS header_file_block,
               ROUND(bytes / 1024 / 1024) AS bytes,
               blocks,
               extents
          FROM dba_segments
         WHERE owner = NVL(UPPER('&owner'), owner)
           AND segment_name = NVL(UPPER('&segment_name'), segment_name)
           AND tablespace_name = NVL(UPPER('&tablespace_name'), tablespace_name)
         ORDER BY bytes DESC
       )
 WHERE ROWNUM < 50;
