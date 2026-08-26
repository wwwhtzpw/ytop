--使用说明， 查询结果中delta开头的列表示跟上次快照之间的增量
--替换语句中的{}括起来的变量， 
--{BEGINTIME} {INTERVAL} 定义要查看的时间段, 
--{EVENT}为v$system_event中的等待事件名称，比如"log file sync" "free buffer wait" 等
--{PLAN_HASH_VALUE}是要查看的SQL语句在v$sql中对应的plan_hash_value

-- sed -e "s/{BEGINTIME}/'2025-03-01 14.50.00'/g" -e "s/{INTERVAL}/60/g" -e "s/{EVENT}/free buffer wait/g" analyze_snap.sql > a1.sql
-- yasql xxx -f -e a1.sql | tee a1.out

--查看sysstat中CPU TIME的变化
SELECT snap_time, value, delta_value FROM v_sysstat WHERE name = 'CPU TIME' AND snap_time BETWEEN {BEGINTIME} AND TO_DATE({BEGINTIME},'YYYY-MM-DD HH24:MI:SS') + interval '{INTERVAL}' minute;

--查看TPS及RESPONSE TIME变化
WITH tmp_transaction AS (SELECT snap_time, delta_value as total_transactions FROM v_sysstat WHERE name = 'COMMITS'),
     tmp_response    AS (SELECT snap_time, delta_value as total_db_time FROM v_sysstat WHERE name = 'DB TIME')
SELECT t.snap_time, t.total_transactions, r.total_db_time,  r.total_db_time / t.total_transactions as avg_response_time
FROM tmp_transaction t, tmp_response r 
WHERE t.snap_time = r.snap_time AND t.total_transactions > 0 AND t.snap_time BETWEEN {BEGINTIME} AND TO_DATE({BEGINTIME},'YYYY-MM-DD HH24:MI:SS') + interval '{INTERVAL}' minute
ORDER BY t.snap_time;

--查看checkpoint中dirty_queue_length的变化
SELECT snap_time, total_num, dirty_queue_length, delta_dirty_queue_length FROM v_checkpoint WHERE snap_time BETWEEN {BEGINTIME} AND TO_DATE({BEGINTIME},'YYYY-MM-DD HH24:MI:SS') + interval '{INTERVAL}' minute;

--查看system_event中，{EVENT}等待事件，发生次数及等待时间，
SELECT snap_time, total_waits, time_waited, delta_total_waits, delta_time_waited, delta_avg_waittime FROM v_system_event WHERE event = '{EVENT}' 
  AND snap_time BETWEEN {BEGINTIME} AND TO_DATE({BEGINTIME},'YYYY-MM-DD HH24:MI:SS') + interval '{INTERVAL}' minute;

--查看tablespaces中，表空间USERS在两个时间点之间，user_bytes的变化情况
SELECT snap_time, user_bytes, delta_user_bytes from v_tablespaces WHERE tablespace_name = 'USERS' AND snap_time BETWEEN {BEGINTIME} AND TO_DATE({BEGINTIME},'YYYY-MM-DD HH24:MI:SS') + interval '{INTERVAL}' minute;

--查看plan_hash_value=
SELECT snap_time, executions, delta_executions, delta_avg_execution_time FROM v_sql WHERE plan_hash_value={PLAN_HASH_VALUE}  AND snap_time BETWEEN {BEGINTIME} AND TO_DATE({BEGINTIME},'YYYY-MM-DD HH24:MI:SS') + interval '{INTERVAL}' minute;
