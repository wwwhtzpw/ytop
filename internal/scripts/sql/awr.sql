-- File Name: awr.sql
-- Purpose: show awr load profile information
-- Created: 20251212  by  huangtingzhong

SELECT 
    TO_CHAR(END_INTERVAL_TIME, 'yyyymmdd hh24:mi') AS end_time,
    ROUND(SUM(DECODE(stat_name, 'DB TIME', per_second, 0)) / 1000000) AS AAS,
    ROUND(SUM(DECODE(stat_name, 'CPU TIME', per_second, 0)) / 1000000) AS CPU_AAS,
    ROUND(SUM(DECODE(stat_name, 'COMMITS', per_second, 0))) AS COMMIT,
    ROUND(SUM(DECODE(stat_name, 'REDO SIZE', per_second, 0)) / 1024) AS REDO,
    ROUND(SUM(DECODE(stat_name, 'QUERY COUNT', per_second, 0))) AS QCNT,
    ROUND(SUM(DECODE(stat_name, 'BLOCK CHANGES', per_second, 0)) * 8 / 1024) AS BLKCHG,
    ROUND(SUM(DECODE(stat_name, 'LOGONS TOTAL', per_second, 0))) AS LOGON,
    ROUND(SUM(DECODE(stat_name, 'INSERT COUNT', per_second, 0))) AS INSCT,
    ROUND(SUM(DECODE(stat_name, 'PARSE COUNT (HARD)', per_second, 0))) AS PARSE,
    ROUND(SUM(DECODE(stat_name, 'DISK READS', per_second, 0)) * 8 / 1024) AS PHYRD,
    ROUND(SUM(DECODE(stat_name, 'DISK WRITES', per_second, 0)) * 8 / 1024) AS PHYWT,
    ROUND(SUM(DECODE(stat_name, 'BUFFER GETS', per_second, 0))) AS BUFGET,
    ROUND(SUM(DECODE(stat_name, 'EXECUTE COUNT', per_second, 0))) AS EXECNT,
    ROUND(SUM(DECODE(stat_name, 'BUFFER CR GETS', per_second, 0))) AS BUFCR
FROM (
    SELECT 
        a.instance_number,
        a.END_INTERVAL_TIME,
        b.stat_name,
        CASE 
            WHEN a.prev_startup_time IS NULL THEN NULL
            WHEN a.prev_startup_time != a.STARTUP_TIME 
                 OR a.prev_inst_change_time != a.INST_CHANGE_TIME THEN NULL
            WHEN a.elapsed_time_seconds > 0 
            THEN (b.VALUE - LAG(b.VALUE) OVER(
                PARTITION BY a.STARTUP_TIME, b.stat_name, a.instance_number 
                ORDER BY a.snap_id
            )) / a.elapsed_time_seconds
            ELSE NULL
        END AS per_second
    FROM (
        SELECT 
            s.snap_id,
            s.instance_number,
            s.END_INTERVAL_TIME,
            s.STARTUP_TIME,
            s.INST_CHANGE_TIME,
            EXTRACT(DAY FROM s.END_INTERVAL_TIME - s.BEGIN_INTERVAL_TIME) * 86400 +
            EXTRACT(HOUR FROM s.END_INTERVAL_TIME - s.BEGIN_INTERVAL_TIME) * 3600 +
            EXTRACT(MINUTE FROM s.END_INTERVAL_TIME - s.BEGIN_INTERVAL_TIME) * 60 +
            EXTRACT(SECOND FROM s.END_INTERVAL_TIME - s.BEGIN_INTERVAL_TIME) AS elapsed_time_seconds,
            LAG(s.STARTUP_TIME) OVER (
                PARTITION BY s.dbid, s.instance_number 
                ORDER BY s.snap_id
            ) AS prev_startup_time,
            LAG(s.INST_CHANGE_TIME) OVER (
                PARTITION BY s.dbid, s.instance_number 
                ORDER BY s.snap_id
            ) AS prev_inst_change_time
        FROM wrm$_snapshot s
    ) a,
    (
        SELECT 
            snap_id,
            instance_number,
            stat_name,
            SUM(VALUE) AS VALUE
        FROM (
            SELECT 
                a.snap_id,
                a.instance_number,
                b.NAME AS stat_name,
                a.value AS VALUE
            FROM WRH$_SYSSTAT a
            INNER JOIN V$STATNAME b ON a.STAT_ID = b.STATISTIC#
            WHERE b.NAME IN (
                'DB TIME',
                'CPU TIME',
                'COMMITS',
                'REDO SIZE',
                'QUERY COUNT',
                'BLOCK CHANGES',
                'LOGONS TOTAL',
                'INSERT COUNT',
                'PARSE COUNT (HARD)',
                'DISK READS',
                'DISK WRITES',
                'BUFFER GETS',
                'EXECUTE COUNT',
                'BUFFER CR GETS'
            )
        )
        GROUP BY snap_id, instance_number, stat_name
    ) b
    WHERE a.instance_number = b.instance_number
      AND a.snap_id = b.snap_id
)
GROUP BY END_INTERVAL_TIME
ORDER BY END_INTERVAL_TIME
/
