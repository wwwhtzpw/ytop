#!/bin/bash
#
# 缺省每间隔30秒，获取一次快照，写入对应表，间隔时长可指定
#

# 定义监控对象，注意对象中可能的记录数，如果记录数量较大，监控脚本可能对系统性能有较大影响，
# 对记录数大的目标，可以设置按那个列取前TOPN条记录，下面数组定义中，v$sql按cpu_time列获取前TOPN条记录
TOPN=10
MONITOR_LIST=("v\$sysstat" "v\$system_event" "v\$checkpoint" "v\$spinlock" "dba_tablespaces" "v\$sql" "v\$session" "v\$buffer_pool_statistics" "v\$logfile" "v\$buffer_access_statistics")
TOP_BY_COLUMN=("" "" "" "" "" "CPU_TIME" "" "" "" "")

# 调用yasql执行SQL语句, 每次调用产生一次数据库连接/断开
function execute_sql()
{
  yasql ${DBURL} -c "$*"
}

# 创建保存快照的表，表名将 v$ 或 dba_ 替代为 snap_，另外增加字段snap_time记录获取快照的时间点
function create_snap_table()
{
  local table_name=$(echo $1)
  local snap_table_name=snap_$(echo $1 | sed -e 's/^v\$//' -e 's/^dba_//')

  echo "Create snapshot table ${snap_table_name} for ${table_name}"
  execute_sql "CREATE TABLE ${snap_table_name} AS (SELECT current_timestamp AS snap_time, a.* FROM ${table_name} a LIMIT 0)"
  execute_sql "CREATE INDEX ${snap_table_name}_idx_snap_time on  ${snap_table_name}(snap_time)"
}

# 创建快照表的相关视图，增加了相邻snap_time之间的增量计算列，分析时可直接SELECT视图
function create_view_for_snap_table()
{
echo "creating view..."
  execute_sql "CREATE OR REPLACE VIEW v_sysstat AS \
    SELECT a.*, value - lag(value) OVER(PARTITION BY name ORDER BY snap_time) as delta_value \
    FROM snap_sysstat a;"

  execute_sql "CREATE OR REPLACE VIEW v_system_event AS \
    SELECT b.*, b.delta_time_waited/DECODE(b.delta_total_waits,0,1,null,1,b.delta_total_waits) as delta_avg_waittime \
    FROM (SELECT a.*, total_waits - lag(total_waits) OVER(PARTITION BY event ORDER BY snap_time) as delta_total_waits, \
            time_waited - lag(time_waited) OVER(PARTITION BY event ORDER BY snap_time) as delta_time_waited 
          FROM snap_system_event a) b;"

  execute_sql "CREATE OR REPLACE VIEW v_checkpoint AS \
    SELECT a.*, dirty_queue_length - lag(dirty_queue_length) OVER(ORDER BY snap_time) as delta_dirty_queue_length, \
      total_num - lag(total_num) OVER(ORDER BY snap_time) as delta_total_num, \
      schedule_num - lag(schedule_num) OVER(ORDER BY snap_time) as delta_schedule_num \
    FROM snap_checkpoint a"

  execute_sql "CREATE OR REPLACE VIEW v_spinlock AS \
    SELECT a.*, times - lag(times) OVER(PARTITION BY name ORDER BY snap_time) as delta_times \
    FROM snap_spinlock a"

  execute_sql "CREATE OR REPLACE VIEW v_tablespaces AS \
    SELECT a.*, user_bytes - lag(user_bytes) OVER(PARTITION BY tablespace_name ORDER BY snap_time) as delta_user_bytes \
    FROM snap_tablespaces a"

  execute_sql "CREATE OR REPLACE VIEW v_sql AS \
    SELECT b.*, b.delta_cpu_time / DECODE(b.delta_executions,0,1,null,1,b.delta_executions) as delta_avg_execution_time \
    FROM (SELECT a.*, cpu_time  - lag(cpu_time) OVER(PARTITION BY plan_hash_value ORDER BY snap_time) as delta_cpu_time, \
            executions  - lag(executions) OVER(PARTITION BY plan_hash_value ORDER BY snap_time) as delta_executions
          FROM snap_sql a) b;"
}

#
# Main
#
DBURL=${1}
sleep_interval=${2:-30}

# 创建快照
for table_name in ${MONITOR_LIST[*]}; do
  create_snap_table ${table_name} 
done

# 创建相关视图，视图中增加了增量计算，直接访问视图，可查看指标变化情况
create_view_for_snap_table

while true
do
  snap_time=$(date "+%F %T")
  echo ${snap_time}" getting snapshot......"
  index=0
  for table_name in ${MONITOR_LIST[*]}; do
    snap_table_name=snap_$(echo ${table_name} | sed -e 's/v\$//' -e 's/dba_//')
    top_by_column=${TOP_BY_COLUMN[${index}]}
    if [[ "${top_by_column}" == "" ]]; then
      execute_sql "INSERT INTO ${snap_table_name} SELECT '${snap_time}', a.* FROM ${table_name} a" > /dev/null &
    else
      execute_sql "INSERT INTO ${snap_table_name} SELECT '${snap_time}', a.* FROM ${table_name} a ORDER BY ${top_by_column} DESC LIMIT ${TOPN}" > /dev/null &
    fi
    index=$((index+1))
  done
  sleep ${sleep_interval}
done
