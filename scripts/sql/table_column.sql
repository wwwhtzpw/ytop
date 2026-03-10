-- File Name:table_column.sql
-- Purpose: display table column information
-- Created: 20251201  by  huangtingzhong

col owner              for   a15
col table_name         for   a25
col COLUMN_NAME        for   a25  
col l_t                for   a5
col degree             for   a6
col part               for   a4
col LAST_ANALYZED      for   a25
col NUM_ROWS           for   a10
col blocks             for   a10
col EMPTY_BLOCKS       for   a5
col d_type             for   a20
col NUM_DISTINCT       for   a10
col N                  for   a1
col NUM_NULLS          for   a8
col sample_size        for   a10
col HISTOGRAM          for   a10
col Tablespacename     for   a15


SELECT a.OWNER,
       a.TABLE_NAME,
       a.COLUMN_NAME,
       a.data_type || '(' || a.data_length || ')' d_type,
       b.NUM_DISTINCT||'' NUM_DISTINCT,
       a.NULLABLE||'' N,
       b.NUM_NULLS||'' NUM_NULLS,
       b.DENSITY,
       b.NUM_BUCKETS,
       b.AVG_COL_LEN,
       b.sample_size||'' sample_size,
       substr(b.HISTOGRAM,0,5) HISTOGRAM,
       b.LAST_ANALYZED
  FROM DBA_TAB_COLS a,DBA_TAB_COL_STATISTICS b
 WHERE   a.owner =nvl(UPPER('&&owner'),  a.owner)
         and a.table_name =nvl(UPPER('&&tablename'),  a.table_name)
       and a.owner=b.owner(+) and a.table_name=b.table_name(+) and a.column_name=b.column_name(+)
 ORDER BY owner,table_name,COLUMN_ID;
