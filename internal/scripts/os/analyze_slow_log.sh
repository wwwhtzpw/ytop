#!/bin/bash
# 名称：analyze_slow_log.sh
# 功能：列出按执行时间排序的topN条SQL执行时间及返回记录数
#       统计慢SQL发生总次数，每个SQL_ID发生的次数、总执行时间、平均执行时间、首次、最后一次捕获时间、时间跨度
#       可指定分拆时长，将慢SQL日志分拆成不同时段，查看不同时段内慢SQL发生的情况
# 适配系统：Linux
# 运行身份：任何用户，有慢SQL日志文件的读权限即可
# 日志文件：使用变量SLOW_LOG_SUMMARY指定
# 参数使用：./analyze_slow_log.sh 慢SQL日志文件 分拆时长
# 使用示例：./analyze_slow_log.sh slow.log 3600
# 版本：1.0
# 更新日期：2026-02-07
# 变动记录： 

SLOW_LOG_SUMMARY=slow.log.sum.$(date "+%Y%m%d_%H%M%S")
# 按执行时间最慢的前N条SQL，有可能同一条SQL出现多次
TOPN=10
# 如需保留分拆后的慢SQL日志，设置为非0数字
KEEP_SPLIT_SLOW_LOG_FILE=0

# 重复显示字符串N次
function repeat()
{
  local char=$1
  local repeat=$2
  for i in $(seq 1 ${repeat}); do
    printf ${char}
  done
  # 添加回车
  echo ""
}
# 显示慢SQL日志中开始、结束时间，慢SQL发生次数，每条慢SQL发生次数，累积执行时间、平均执行时间，第一次最后一次捕获时间
function sum_slow_log
{
  local slow_log_file=$1
  local id=0
  # 获取慢SQL的SQL_ID列表
  grep SQL_ID ${slow_log_file} | awk '{print $3}' > id.list
  local total_slow_sql=$(wc -l id.list | awk '{print $1}')

  echo ""; repeat "-" 108
  printf "%16s %-50s\n" "Slow log file:" "${slow_log_file}"
  printf "%16s %-50s\n" "Start time:" "$(grep "# TIME" ${slow_log_file} | head -1 | awk '{print $3" "$4}')"
  printf "%16s %-50s\n" "End   time:" "$(grep "# TIME" ${slow_log_file} | tail -1 | awk '{print $3" "$4}')"
  printf "%16s %-50s\n" "Total slow sql:" "${total_slow_sql}"

  printf "\n%15s %12s %12s %12s %19s %19s %12s\n"  "SQL_ID" "Count" "Total_time" "Average_time" "First_time" "Last_time" "Time_span"
  for id in $(sort id.list | uniq); do
    local id_count=$(grep $id id.list | wc -l)
    local total_execution_time=0
    for execution_time in $(grep -B4 ${id} ${slow_log_file} | grep COST_EXECUTE_TIME | awk '{print $3}' | awk -F'.' '{print $1}'); do
      total_execution_time=$((total_execution_time+execution_time))
    done
    local avg_execution_time=$((total_execution_time/id_count))
    local first_time=$(grep -B6 ${id} ${slow_log_file} | grep "# TIME" | head -1 | awk '{print $3" "$4}' | awk -F'.' '{print $1}')
    local last_time=$(grep -B6 ${id} ${slow_log_file} | grep "# TIME" | tail -1 | awk '{print $3" "$4}' | awk -F'.' '{print $1}')
    local first_time_in_second=$(date -d "${first_time}" +%s)
    local last_time_in_second=$(date -d "${last_time}" +%s)
    local time_span=$((last_time_in_second-first_time_in_second))
    if [[ ${id_count} -eq 1 ]]; then
      time_span=${total_execution_time}
    fi
    printf "%15s %12d %12d %12d %10s %8s %10s %8s %12d\n"  ${id}  ${id_count} ${total_execution_time} ${avg_execution_time} ${first_time} ${last_time} ${time_span}
  done | sort -rnk 2
  rm id.list
}

# 列出按执行时间排序topN条SQL的SQL_ID及执行时间
function get_topN()
{
  local slow_log_file=$1
 
  repeat "-" 96 | tee -a ${SLOW_LOG_SUMMARY}
  echo -e "Slow log file: "${slow_log_file}
  echo -e "Top ${TOPN} SQL by execution time" | tee -a ${SLOW_LOG_SUMMARY}
  printf "%15s %18s %18s\n"  "SQL_ID" "Execution_time" "Rows" | tee -a ${SLOW_LOG_SUMMARY}
  repeat "-" 96 | tee -a ${SLOW_LOG_SUMMARY}

  for execution_time in $(grep "COST_EXECUTE_TIME" ${slow_log_file} | awk '{print $3}' | sort -rnk 1 | head -${TOPN})
  do
    id=$(grep -A3 $execution_time ${slow_log_file} | grep SQL_ID |  awk '{print $3}')
    rows=$(grep -A2 $execution_time ${slow_log_file} | grep ROWS_SENT |  awk '{print $3}')
    printf "%15s %18s %18s\n"  ${id} ${execution_time} ${rows} | tee -a ${SLOW_LOG_SUMMARY}
  done
}

#
# Main
#

slow_log_file=$1
# 第二传入参数，以之为分拆单位，统计此时间段内发生的慢SQL情况，默认300秒
split_by_seconds=${2:-300}

# 列出按执行时间排序topN条SQL的SQL_ID及执行时间
get_topN ${slow_log_file} | tee  ${SLOW_LOG_SUMMARY}

# 获取全部汇总信息
sum_slow_log ${slow_log_file} | tee -a ${SLOW_LOG_SUMMARY}

# 按参数split_by_seconds指定的时长分拆慢SQL日志，默认5分钟，汇总此时间段发生的慢SQL

# 生成慢SQL发生时间-行号列表
#sed -n '/# TIME/=' ${slow_log_file} > line.list
awk '{print NR" "$0}' ${slow_log_file} | grep "# TIME" > line.list

first_line=$(head -1 line.list | awk '{print $1}')
# 获取开始时间
start_time=$(sed -n "${first_line} p" ${slow_log_file} | awk '{print $3" "$4}' | awk -F'.' '{print $1}')
# 计算截止时间
end_time=$(date -d "@$(($(date -d "${start_time}" "+%s") + ${split_by_seconds}))" "+%F %T")
while read line; do
  #cur_time=$(sed -n "${line} p" ${slow_log_file} | awk '{print $3" "$4}' | awk -F'.' '{print $1}')
  cur_line=$(echo $line | awk '{print $1}')
  cur_time=$(echo $line | awk '{print $4" "$5}')
  if [[ "${cur_time}" > "${end_time}" ]]; then
    #echo $line $first_line $last_line $start_time $end_time $cur_time
    last_line=$((cur_line-1))
    split_slow_log_file=${slow_log_file}.${first_line}
    # 分拆慢SQL日志
    sed -n "${first_line},${last_line} p" ${slow_log_file} > ${split_slow_log_file}
    # 汇总分拆的慢SQL日志
    sum_slow_log ${split_slow_log_file} | tee -a ${SLOW_LOG_SUMMARY}
    if [[ ${KEEP_SPLIT_SLOW_LOG_FILE} -eq 0 ]]; then
      rm ${split_slow_log_file}
    fi
    first_line=${cur_line}
    start_time=${cur_time}
    end_time=$(date -d "@$(($(date -d "${start_time}" "+%s") + ${split_by_seconds}))" "+%F %T")
  fi
done < line.list
rm line.list
# 汇总最后一个分拆慢SQL日志
last_line=${cur_line}
split_slow_log_file=${slow_log_file}.${first_line}
sed -n "${first_line},$ p" ${slow_log_file} > ${split_slow_log_file}
sum_slow_log ${split_slow_log_file} | tee -a ${SLOW_LOG_SUMMARY}
if [[ ${KEEP_SPLIT_SLOW_LOG_FILE} -eq 0 ]]; then
  rm ${split_slow_log_file}
fi
