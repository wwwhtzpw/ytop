-- File Name:yfs_diskgroup.sql
-- Purpose: display yfs diskgroup information
-- Created: 20260303  by  huangtingzhong
col group_name          for  a15
col type                for  a6
col used_mb             for a10
col free_mb             for a10

SELECT
    name                                     group_name
  , block_size                               block_size
  , AU_SIZE                                  au_size
  ,redundancy
  , state                                    state
  , type                                     type
  , total_mb||''                                 total_mb
  , free_mb	||''  			    free_mb
  , (total_mb - free_mb)||''                       used_mb
  , ROUND((1- (free_mb / total_mb))*100, 2)  pct_used
FROM
    v$yfs_diskgroup
WHERE
    total_mb != 0
ORDER BY
    name
/

