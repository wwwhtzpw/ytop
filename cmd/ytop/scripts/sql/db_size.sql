-- File Name: db_size.sql
-- Purpose: show tablespace usage information
-- Created: 20251208  by  huangtingzhong

SELECT df.tablespace_name                         AS "Tablespace",
       ROUND(df.bytes / (1024 * 1024))            AS "Size_MB",
       ROUND(SUM(fs.bytes) / (1024 * 1024))       AS "Free_MB",
       ROUND(SUM(fs.bytes) * 100 / df.bytes)      AS "% Free",
       ROUND((df.bytes - SUM(fs.bytes)) * 100 / df.bytes) AS "% Used"
  FROM dba_free_space fs
 RIGHT JOIN (
        SELECT tablespace_name,
               SUM(bytes) AS bytes
          FROM dba_data_files
         GROUP BY tablespace_name
       ) df
    ON fs.tablespace_name = df.tablespace_name
 GROUP BY df.tablespace_name, df.bytes
 ORDER BY df.tablespace_name;
