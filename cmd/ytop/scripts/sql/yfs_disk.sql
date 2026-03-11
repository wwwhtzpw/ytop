-- File Name:yfs_disk.sql
-- Purpose: display yfs disk information
-- Created: 20260303  by  huangtingzhong
col group_name          for  a15
col FAILGROUP_LABEL     for  a10
col disk_path           for  a30
col disk_name           for  a10
col mount_status        for  a10
col redundancy          for  a10
col total_mb            for  a10
SELECT NVL (a.name, '[CANDIDATE]') group_name,
         b.FAILGROUP_LABEL,
         b.PATH disk_path,
         b.name disk_name,
         b.mount_status,
         b.redundancy,
         b.total_mb||'' total_mb,
         (b.total_mb - b.free_mb) used_mb,
         ROUND (
            (1 - (b.free_mb / DECODE (b.total_mb, 0, 1, b.total_mb))) * 100,
            2)
            pct_used
    FROM v$yfs_diskgroup a ,v$yfs_disk b where a.id(+)=b.group_number
ORDER BY a.name, b.PATH
/
