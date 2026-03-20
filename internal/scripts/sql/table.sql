-- File Name:table.sql
-- Purpose: display table and index column information
-- Created: 20260303  by  huangtingzhong

col owner              for   a15
col table_name         for   a25
col l_t                for   a5
col degree             for   a6
col part               for   a4
col LAST_ANALYZED      for   a25
col NUM_ROWS           for   a10
col blocks             for   a10
col EMPTY_BLOCKS       for   a5
col COLUMN_NAME        for   a15
col d_type             for   a20
col NUM_DISTINCT       for   a10
col N                  for   a1
col NUM_NULLS          for   a8
col sample_size        for   a10
col HISTOGRAM          for   a10
col Tablespacename     for   a15

  SELECT a.owner,
         a.TABLE_NAME,
         -- TABLESPACE_NAME,
         a.LOGGING||'.'||a.TEMPORARY l_t,
         LTRIM (a.DEGREE) DEGREE,
         a.PARTITIONED as part,
         a.NUM_ROWS||'' NUM_ROWS,
         a.BLOCKS||'' BLOCKS,
         a.EMPTY_BLOCKS||'' EMPTY_BLOCKS,
         b.AVG_SPACE,
         b.AVG_ROW_LEN,
         trunc((b.blocks*tp.block_size)/1024/1024) block_size,
         trunc((b.AVG_ROW_LEN*b.NUM_ROWS)/1024/1024) avg_size,
         b.STALE_STATS,
         a.LAST_ANALYZED
    FROM dba_tables a
        , dba_tab_statistics b
        ,dba_tablespaces tp
   WHERE     a.owner = b.owner(+)
         AND a.table_name = b.table_name(+)
         and a.tablespace_name=tp.tablespace_name
         and a.owner =nvl(UPPER('&&owner'),  a.owner)
         and a.table_name =nvl(UPPER('&&tablename'),  a.table_name)
ORDER BY owner, table_name;

col owner_table_index    for     a55
col INDEX_TYPE           for     a10
col UNIQUENESS           for     a1
col PCT                  for     a3
col D_KEYS               for     a10  
col leaf_blocks          for     a10
col num_rows             for     a10
col post                 for     a4
col l                    for     a1
col COLUMNNAME           for     a25

SELECT a.owner||'.'||a.table_name||'.'||b.index_name owner_table_index,
       a.Tablespace_Name Tablespacename,
       a.status,
       a.index_type,
       a.uniqueness,
       a.pct_free||''  pct,
       a.logging l,
       a.blevel||'' L,
       a.distinct_keys||'' d_keys,
       a.leaf_blocks||'' leaf_blocks,
       --a.DEGREE,
       a.num_rows||'' num_rows,
       a.partitioned part,
       b.Column_Position||'' post,
       b.Column_Name     Columnname
  FROM dba_indexes a, dba_ind_Columns b
 WHERE a.owner = nvl(upper('&&owner'),a.owner)
   and a.Table_Name = nvl(upper('&&tablename'), a.table_name)
   AND b.Index_Name = a.Index_Name
   and a.owner=b.index_owner
   and a.table_owner=b.index_owner
 ORDER BY owner_table_index,post;
