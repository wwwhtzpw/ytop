-- YashanDB: 数据文件与临时文件一览（由 Oracle DBA_DATA_FILES + DBA_TEMP_FILES 查询改写）
-- 变量参数: &&tablespace_name、&&file_id（不填或留空表示不过滤；运行前 DEFINE 或由客户端提示输入）。
-- 未替换时（如 MCP 直接执行）视为不过滤，避免 TO_NUMBER('&&file_id') 报错。

SELECT a.tablespace_name,
       a.file_name,
       a.file_id,
       NULL AS relative_fno,
       SUBSTR(a.status, 1, 10) AS status,
       a.autoextensible,
       TRUNC(a.bytes / 1024 / 1024) AS bytes,
       TRUNC(a.maxbytes / 1024 / 1024) AS maxbytes
  FROM dba_data_files a
 WHERE a.tablespace_name = NVL('&&tablespace_name',a.tablespace_name)
   AND  a.file_id = NVL('&&file_id', a.file_id)
UNION ALL
SELECT a.tablespace_name,
       a.file_name,
       a.file_id,
       a.relative_fno,
       SUBSTR(a.status, 1, 10) AS status,
       a.autoextensible,
       TRUNC(a.bytes / 1024 / 1024) AS bytes,
       TRUNC(a.maxbytes / 1024 / 1024) AS maxbytes
  FROM dba_temp_files a
 WHERE a.tablespace_name = NVL('&&tablespace_name',a.tablespace_name)
   AND a.file_id = NVL('&&file_id', a.file_id)
 ORDER BY 1, 3;
