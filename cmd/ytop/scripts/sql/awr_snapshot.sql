-- File Name: awr_snapshot.sql
-- Purpose: show snapshot time and db time
-- Created: 20251212  by  huangtingzhong


col i                      for a1

WITH snapshot_info AS (
    SELECT
        snap_id,
        dbid,
        instance_number,
        BEGIN_INTERVAL_TIME,
        END_INTERVAL_TIME,
        STARTUP_TIME,
        INST_CHANGE_TIME,
        status,
        error_count,
        BEGIN_INTERVAL_TIME begin_time,
        END_INTERVAL_TIME end_time
    FROM wrm$_snapshot WHERE BEGIN_INTERVAL_TIME> sysdate - &days
),
stat_values AS (
    SELECT
        s.snap_id,
        s.dbid,
        s.instance_number || '' AS i,
        s.begin_time,
        s.end_time,
        s.status,
        s.error_count,
        st.value AS current_value,
        LAG(st.value) OVER (
            PARTITION BY s.dbid, s.instance_number
            ORDER BY s.snap_id
        ) AS prev_value,
        LAG(s.INST_CHANGE_TIME) OVER (
            PARTITION BY s.dbid, s.instance_number
            ORDER BY s.snap_id
        ) AS prev_inst_change_time,
        s.INST_CHANGE_TIME AS current_inst_change_time,
        LAG(s.STARTUP_TIME) OVER (
            PARTITION BY s.dbid, s.instance_number
            ORDER BY s.snap_id
        ) AS prev_startup_time,
        s.STARTUP_TIME AS current_startup_time
    FROM snapshot_info s
    INNER JOIN WRH$_SYSSTAT st ON (
        s.snap_id = st.snap_id
        AND s.dbid = st.dbid
        AND s.instance_number = st.instance_number
    )
    WHERE st.stat_id = 604
)
SELECT
    snap_id,
    dbid,
    i,
    to_char(begin_time, 'yyyy-mm-dd hh24:mi:ss') begin_time,
    to_char(end_time, 'yyyy-mm-dd hh24:mi:ss') end_time,
    ROUND(EXTRACT(DAY FROM  end_time - begin_time) * 1440 +
          EXTRACT(HOUR FROM end_time - begin_time) * 60 +
          EXTRACT(MINUTE FROM end_time - begin_time) +
          EXTRACT(SECOND FROM end_time - begin_time) / 60, 2) elapsed_time,
    status,
    error_count,
    CASE
        WHEN prev_inst_change_time IS NULL THEN NULL  -- First snapshot
        WHEN prev_inst_change_time != current_inst_change_time
             OR prev_startup_time != current_startup_time THEN NULL  -- Instance restarted
        ELSE current_value - prev_value  -- Normal increment
    END AS  db_time,
    CASE
        WHEN prev_inst_change_time IS NULL THEN 'First Snapshot'
        WHEN prev_inst_change_time != current_inst_change_time
             OR prev_startup_time != current_startup_time THEN 'Instance Restarted'
        ELSE 'Normal'
    END AS status_flag
FROM stat_values
ORDER BY dbid,snap_id;
