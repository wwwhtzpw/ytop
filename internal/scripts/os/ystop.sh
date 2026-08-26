#!/bin/bash
##########################################################################################
# Description:
#   Interactive monitoring tools for YashanDB
#   Monitor database activity by press a key
#     d - database overview
#     D - database detail
#     b - buffer pool
#     s - SQL statement
#       z - Select orderby column
#     l - lock & spinlock
#     S - session   
#     t - tablespace
#     T - table
#     w - wait event
#     m - memory pool
#     v - display version
#     q - exit
# 
# Example:
#  ./ystop.sh 
#  ./ystop.sh sys/yasdb_123@192.168.1.2:1688
#
# Written by: Zhang Limin
# Last update: 2025-08-28
##########################################################################################

YSTOP_VERSION=1.0
DBURL=sys/yasdb_123@0.0.0.0:1688
ROWSRETUEN=30
TOPN=5
SLEEPINTERVAL=5

hilightString()
{
  local string=$1
  local length=${2}
  if [[ ${length} -lt ${#string} ]]; then
    length=${#string}
  fi
  HILIGHTCOLOR='\E[92;100m' # 亮绿色闪动
  RES='\E[0m'                # 清除颜色
  printf "${HILIGHTCOLOR}%${length}s${RES}" $string
}

hilightString2()
{
  local stringKey=$1
  local stringValue=$2
  local length=${3}
  local lenKey=${#stringKey}
  local lenValue=$((length-lenKey))

  HILIGHTCOLOR='\E[6;92;49;5m' # 亮绿色
  RES='\E[0m'                # 清除颜色
  printf "%-${lenKey}s" "${stringKey}"
  printf "${HILIGHTCOLOR}%${lenValue}s${RES}" "$stringValue"
}

# 调用yasql执行SQL语句, 每次调用产生一次数据库连接/断开
function exeSQL()
{
   yasql ${DBURL} -c "$*"
}

# 显示数据库大小
function displayDbSize()
{
  local databaseSize=$(exeSQL  "SELECT  CAST((sum(total_bytes-user_bytes))/1024/1024/1024 AS decimal(15,2))||'/'|| \
                                CAST(sum(total_bytes/1024/1024/1024) as decimal(15,2)) FROM dba_tablespaces"|sed -n '4 p'|sed 's/ //g')
  hilightString2 "  DB size(GB):" "${databaseSize}" 56
}

# 显示DATA BUFFER命中率
function displayDataBufferHitRatio()
{
  local bpHitratio=$(exeSQL "SELECT cast((a.bpgets - b.bpreads)*100/a.bpgets as decimal(6,2)) FROM \
                             (SELECT value bpgets FROM v\$sysstat WHERE statistic#=120) a, \
                             (SELECT value bpreads FROM v\$sysstat WHERE statistic#=131) b"|grep -A1 "\-\-"|tail -1|sed 's/ //g')
  hilightString2 " Data buffer(MB):${BPSIZE}; Hit ratio:" "${bpHitratio}" 44
}

# 显示会话状况
function displaySessionStats()
{
  local curSessions=$(exeSQL "SELECT count(1) FROM v\$session WHERE type='USER'"|grep -A1 "\-\-"|tail -1|sed 's/ //g')
  local actSessions=$(exeSQL "SELECT count(1) FROM v\$session WHERE type='USER' and status='ACTIVE'"|grep -A1 "\-\-"|tail -1|sed 's/ //g')
  local maxSessions=$(exeSQL "SELECT * FROM v\$parameter"|grep MAX_SESSIONS|awk '{print $2}')
  hilightString2 "  Max/Current/Active sessions:" "${maxSessions}/${curSessions}/${actSessions}" 56
}

# 显示SQL缓存使用情况
function displaySqlStats()
{
  local sqlNumber
  local memoryUsed
  read -r sqlNumber memoryUsed <<< $(exeSQL "SELECT count(*), sum(sharable_mem)/1024/1024 FROM v\$sql"|grep -A1 "\-\-"|tail -1)
  printf "%-12s" " SQL in cache:" 
  hilightString ${sqlNumber} 10
  printf "%-36s" "Memory used(MB):" 
  hilightString ${memoryUsed} 10
}

# 显示脏页队列长度
function displayDirtyQueueLength()
{
  local dirtyQueueLength=$(exeSQL "SELECT dirty_queue_length FROM v\$checkpoint"|grep -A1 "\-\-"|tail -1)
  hilightString2 " Dirty queue length:" "${dirtyQueueLength}" 44
}

# 显示锁数量
function displayLockStats()
{
  local totalLocks=$(exeSQL "SELECT count(*) FROM v\$lock"|grep -A1 "\-\-"|tail -1)
  hilightString2 " Total locks:" "${totalLocks}" 44
}

# 显示VM使用状况
function displayVmStats()
{
  local TotalBlocks
  local FreeBlocks
  local SwapoutBlocks
  read -r TotalBlocks FreeBlocks SwapoutBlocks <<< $(exeSQL "SELECT sum(total_blocks), sum(free_blocks), sum(swapped_out_blocks) FROM v\$vm"|grep -A1 "\-\-"|tail -1)
  hilightString2 "  Total/Free/Swapout VM blocks:" "${TotalBlocks}/${FreeBlocks}/${SwapoutBlocks}" 56
}

# 显示TPS及Response Time, QPS 及每秒产生的REDO BLOCK数量
function displayTpsAndResponseTime()
{
  TXS=$(exeSQL "SELECT cast(sum(value) as bigint) FROM v\$sysstat WHERE name IN ('COMMITS','ROLLBACKS')"|grep -A1 "\-\-"|tail -1)
  DBTIME=$(exeSQL "SELECT value FROM v\$sysstat WHERE name='DB TIME'"|grep -A1 "\-\-"|tail -1)
  QUERIES=$(exeSQL "SELECT cast(sum(value) as bigint) FROM v\$sysstat WHERE name in ('INSERT COUNT', 'UPDATE COUNT', 'DELETE COUNT', 'QUERY COUNT')"|grep -A1 "\-\-"|tail -1)
  #QUERIES=$(exeSQL "SELECT value FROM v\$sysstat WHERE name='QUERY COUNT'"|grep -A1 "\-\-"|tail -1)
  REDOBLOCKS=$(exeSQL "SELECT value FROM v\$sysstat WHERE name='REDO BLOCKS WRITTEN'"|grep -A1 "\-\-"|tail -1)
  local deltaTXS=$((TXS-preTXS))
  local deltaDBTIME=$((DBTIME-preDBTIME))
  local deltaQUERIES=$((QUERIES-preQUERIES))
  local deltaREDOBLOCKS=$((REDOBLOCKS-preREDOBLOCKS))
  local tps=0
  local responseTime=0
  local qps=0
  local redoBlocksPerSecond=0
  snapTime=$(date "+%s")
  local interval=$((snapTime-lastSnapTime))
  if [[ ${deltaTXS} -gt 0 ]]; then
    tps=$((deltaTXS / interval))
    responseTime=$((deltaDBTIME * 1000 / deltaTXS))
    qps=$((deltaQUERIES / interval))
    redoBlocksPerSecond=$((deltaREDOBLOCKS / interval))
  fi
  hilightString2 "Transactions per second:" ${tps} 34
  hilightString2 " Response time(µs):" ${responseTime} 44
  echo ""
  hilightString2 "  REDO Blocks per second:" ${redoBlocksPerSecond} 56
  hilightString2 " SQL statements per second:" ${qps} 44
  #hilightString2 " Queries per second:" ${qps} 44
  preTXS=${TXS}; preDBTIME=${DBTIME};
  preQUERIES=${QUERIES}; preREDOBLOCKS=${REDOBLOCKS}
  lastSnapTime=${snapTime}
}

# 显示第一笔交易的session id 及交易开始时间
function displayFirstTransaction()
{
  local sid
  local startDate
  local startTime
  read -r sid startDate startTime <<<  $(exeSQL "SELECT sid, cast(scn_to_timestamp(start_scn) as char(27)) FROM v\$transaction ORDER BY start_scn LIMIT 1"|sed -n '4p')
  if [[ "${sid}" == "" ]]; then
    sid="null"
  fi
  hilightString2 "  Session ID of the first transaction:" ${sid} 56
  hilightString2 " Start time:" "${startTime}" 44
}

# 从v$sysstat获取值不为0的系统运行指标
function listDbDetail()
{
  displayTpsAndResponseTime
  exeSQL "WITH tmp(id, name, value) AS (SELECT rownum, name, value FROM v\$sysstat WHERE value > 0) \
    SELECT cast(t1.name as varchar(40)) as name, t1.value, \
           cast(t2.name as varchar(40)) as name, t2.value \
    FROM (SELECT * FROM tmp WHERE id <=50 ) t1 \
    LEFT OUTER JOIN (SELECT * FROM tmp WHERE id > 50) t2 \
    ON t1.id = t2.id - 50"
}

# 列出BUFFER POOL 使用状况
function listBP()
{
  echo $(displayDataBufferHitRatio)
  exeSQL "SELECT * FROM v\$buffer_pool_statistics"
}

# TOP SQL, 可按execution, cpu time, elapsed time, application wait time, average time, disk reads 等指标排序，查看前N条SQL
function topSQL()
{
  local orderbyCol=$1

  echo $(displaySqlStats)
  exeSQL "SELECT executions, parse_calls, cpu_time, elapsed_time, application_wait_time, CAST(elapsed_time/1000/executions AS decimal(20,3))as avg_time_ms,\
                 disk_reads, buffer_gets, plan_hash_value, substr(sql_text,1,60) as sql_text \
          FROM v\$sql WHERE executions > 0 ORDER BY ${orderbyCol} desc LIMIT ${ROWSRETUEN}"
}

# 列出当前应用持有的锁
function listLock()
{
  echo $(displayLockStats)
  exeSQL "SELECT * FROM v\$lock LIMIT ${ROWSRETUEN}"
  exeSQL "SELECT * FROM v\$spinlock WHERE times>0 ORDER BY times DESC LIMIT ${ROWSRETUEN}"
}

# 列出锁等待相关信息
function listLockwait()
{
  echo $(displayLockStats)

  echo "Row lock confict"
  # 检查行锁冲突
  exeSQL "WITH lockwait AS \
    (SELECT sid as request_sid, request as request_lock, id1 as xid FROM v\$lock WHERE request = 'ROW') \
    SELECT l.request_sid, l.request_lock, t.sid as hold_sid FROM lockwait l, v\$transaction t \
    WHERE l.xid = t.xid;"

  echo "Table lock conflict - S wait"
  # 检查表锁冲突 - 共享锁等独占锁
  exeSQL "  WITH lockwait AS\
      (SELECT sid as request_sid, request as request_lock, id1 as tid FROM v\$lock WHERE request = 'TS'),\
      lockhold AS\
      (SELECT DISTINCT gl.sid as hold_sid, gl.id1 as tid FROM  v\$lock gl, lockwait l WHERE gl.id1 = l.tid AND lmode = 'TX')\
    SELECT w.request_sid, w.request_lock, o.owner||'.'||o.object_name as table_name, h.hold_sid FROM lockwait w, lockhold h, dba_objects o\
    WHERE w.tid = h.tid AND w.tid  = o.object_id;"
  
  echo "Table lock conflict - X wait"
  # 检查表锁冲突 - 独占锁等共享锁或独占锁
  exeSQL  "WITH lockwait AS
      (SELECT sid as request_sid, request as request_lock, id1 as tid FROM v\$lock WHERE request = 'TX'),
      lockhold AS
      (SELECT gl.id1 as tid, WM_CONCAT(DISTINCT sid) as hold_sid_list FROM v\$lock gl, lockwait l WHERE gl.id1 = l.tid AND (gl.lmode = 'TS' OR gl.lmode = 'TX') GROUP BY gl.id1)
    SELECT w.request_sid, w.request_lock, o.owner||'.'||o.object_name as table_name, h.hold_sid_list FROM lockwait w, lockhold h, dba_objects o
    WHERE w.tid = h.tid AND w.tid  = o.object_id;"
}


# 列出用户会话(SID<=20为系统会话？)数量、状态，可看到当前正在运行的SQL语句
function listSession()
{
  echo $(displaySessionStats)
  exeSQL "SELECT status, wait_event, count(1) count FROM v\$session WHERE type='USER' GROUP BY status, wait_event"
  exeSQL "SELECT a.sid, cast(a.cli_hostname as char(20)) cli_host, cast(a.cli_program as char(30)) cli_program, b.sql_id, \
            cast(exec_start_time as char(26)) start_time, substr(b.sql_text,1,60) running_sql \
          FROM  v\$session a LEFT JOIN v\$sql b ON a.sql_id = b.sql_id WHERE type='USER' ORDER BY sql_id, exec_start_time LIMIT ${ROWSRETUEN}"
}

# 列出所有表空间状态、空间大小、使用状况
function listTablespace()
{
  echo $(displayDbSize)
  exeSQL "SELECT id, tablespace_name, status, block_size, total_bytes/1024/1024 as \"TOTAL_SIZE(MB)\", \
                 CAST((total_bytes-user_bytes)/1024/1024 AS decimal(15,2)) as \"USED(MB)\",\
                 CAST(user_bytes/1024/1024 AS decimal(15,2)) as \"AVAILABLE(MB)\", CAST(user_bytes/total_bytes*100 AS decimal(5,2)) AS FREE_PERCENT \
          FROM dba_tablespaces LIMIT ${ROWSRETUEN}"
}

# 列出表的数据、索引大小，按数据由大到小排列
function listTable()
{
  exeSQL "with
    tmp_table as (SELECT owner, segment_name table_name, cast(sum(bytes)/1024/1024 as decimal(15,2)) datasize FROM dba_segments \
                    WHERE segment_type in ('TABLE', 'TABLE PARTITION') GROUP BY owner, segment_name ORDER BY datasize DESC LIMIT  ${ROWSRETUEN}), \
    tmp_index as (SELECT i.table_owner, i.table_name, cast(sum(s.bytes)/1024/1024 as decimal(15,2)) indexsize FROM dba_indexes i, dba_segments s \
                    WHERE i.owner = s.owner AND i.index_name = s.segment_name AND s.segment_type IN ('INDEX', 'INDEX PARTITION') \
                    GROUP BY i.table_owner, i.table_name), \
    tmp_lob as (SELECT l.owner, l.table_name, cast(sum(s.bytes)/1024/1024 as decimal(15,2)) lobsize FROM dba_segments s, dba_lobs l \
                    WHERE l.owner = s.owner AND l.segment_name = s.segment_name \
                    GROUP BY l.owner, l.table_name) \
  SELECT cast(d.owner as char(20)) owner, d.table_name, d.datasize, i.indexsize, l.lobsize, m.inserts, m.updates, m.deletes  \
    FROM tmp_table d LEFT JOIN tmp_index i ON d.owner = i.table_owner AND d.table_name = i.table_name \
         LEFT JOIN tmp_lob l ON  d.owner = l.owner AND d.table_name = l.table_name
         LEFT JOIN (SELECT table_owner, table_name, sum(inserts) inserts, sum(updates) updates, sum(deletes) deletes \
                    FROM dba_tab_modifications GROUP BY table_owner, table_name) m ON d.owner=m.table_owner AND d.table_name=m.table_name \
    ORDER BY 3 desc;"
}

# 列出系统发生的等待事件、时间
function listWait()
{
  exeSQL "SELECT event, total_waits, time_waited, cast(time_waited/total_waits as decimal(10,2)) as avg_waittime, total_waits_fg, time_waited_fg, event_id, wait_class \
          FROM v\$system_event WHERE total_waits > 0 order by time_waited desc"
}

# 显示部分配置参数
function listMemory()
{
  exeSQL "SELECT name, cast(value as char(20)) value FROM v\$parameter WHERE name like '%SIZE' order by 1"
}

# 显示版本信息
function listVersion()
{
  echo ""
  echo "ystop.sh version: ${YSTOP_VERSION}"
  echo "yasql version: $(yasql -V)"
  echo "YashanDB server version: "$(exeSQL "SELECT * FROM v\$version"|sed -n '4p')
}

# 显示数据库各项时间花费
function displayDBTime()
{
  local preV
  local curV
  local colA
  mv ./yashandbSnap.cur ./yashandbSnap.pre
  exeSQL "select name, value from v\$sysstat where name like '%TIME' order by value desc limit ${TOPN}"|grep TIME > ./yashandbSnap.cur
  printf "\n%30s %20s %20s\n" "TOP_TIME_SPENT" "CURRENT VALUE" "DELTA VALUE"
  echo "------------------------------------------------------------------------"
  awk -F'TIME' '{print $1}' ./yashandbSnap.cur|while read colA
  do
    preV=$(grep "$colA TIME" ./yashandbSnap.pre|awk -F'TIME' '{print $2}')
    curV=$(grep "$colA TIME" ./yashandbSnap.cur|awk -F'TIME' '{print $2}')
    printf "%30s %20d %20d\n" "$colA TIME" $curV $((curV-preV))
  done
}

# 监控大盘
function listDbOverview()
{
  # 显示TPS及Response time
  displayTpsAndResponseTime

  # 显示数据库第一笔交易的SESSION ID 及开始时间
  #echo ""; displayFirstTransaction

  # 显示数据库大小
  echo ""; displayDbSize

  # 显示DATA BUFFER命中率
  displayDataBufferHitRatio

  # 显示VM使用状况
  echo ""; displayVmStats

  # 显示脏页队列长度
  displayDirtyQueueLength
  
  # 显示SQL缓存使用情况
  #displaySqlStats
  
  # 显示会话状况
  echo ""; displaySessionStats

  # 显示锁数量
  displayLockStats;echo ""

  local headN=$((TOPN+3))
  # 显示 top wait event
  exeSQL "SELECT event as top_event, total_waits, time_waited, average_wait \
          FROM v\$system_event WHERE total_waits > 0 order by time_waited DESC LIMIT ${TOPN}" | head -${headN}

  # 显示 top spinlock
  exeSQL "SELECT name as top_spinlock, times FROM v\$spinlock WHERE times>0 ORDER BY times DESC LIMIT ${TOPN}" | head -${headN}

  # 显示 top DB time 
  displayDBTime

  # 显示 top SQL by cpu_time
  exeSQL "SELECT executions, cpu_time, CAST(cpu_time/1000/executions AS decimal(20,3))as avg_time_ms,\
                 sql_id, substr(sql_text,1,40) as sql_text \
          FROM v\$sql WHERE executions > 0 ORDER BY cpu_time DESC LIMIT ${TOPN}" | head -${headN}

  # 显示 正在运行的SQL语句
  exeSQL "SELECT a.sid, b.sql_id, cast(exec_start_time as char(26)) start_time, substr(b.sql_text,1,60) running_sql \
          FROM  v\$session a LEFT JOIN v\$sql b ON a.sql_id = b.sql_id WHERE a.sql_id IS NOT NULL AND type='USER' ORDER BY exec_start_time LIMIT ${TOPN}" | head -${headN}

}

######## Main ##########

if [[ $# -gt 0 ]]; then
  DBURL=$1
fi

BPSIZE=$(exeSQL "SELECT cast(sum(num_total * block_size)/1024/1024 as int) FROM v\$buffer_pool_statistics"|grep -A1 "\-\-"|tail -1|sed 's/ //g')

preTXS=1
preDBTIME=99

touch ./yashandbSnap.cur ./yashandbSnap.pre
clear

key='d'
preKey='s'
orderbyCol=1
preTXS=0
preDBTIME=0
lastSnapTime=$(date "+%s"); lastSnapTime=$((lastSnapTime-1))

while true
do
  #echo -n "[$(date "+%F %T")] "
  hilightString2 "[" $(date "+%F") 11
  hilightString2 " " $(date "+%T") 9; echo -n "] "
  case ${key} in 
    d) listDbOverview
      ;;
    D) listDbDetail
      ;;
    b) listBP
      ;;
    s) topSQL ${orderbyCol}
      ;;
    l) listLock
      ;;
    L) listLockwait
      ;;
    S) listSession
      ;;
    t) listTablespace
      ;;
    T) listTable
      ;;
    z) if [[ "${preKey}" == "s" ]]; then
        read -p "Order by column:" orderbyCol
        key='s'
        if [[ ! ${orderbyCol} =~ [0-9] ]]; then
          orderbyCol=1
        fi
       fi
       topSQL $orderbyCol
      ;;
    w) listWait
      ;;
    m) listMemory
      ;;
    v) listVersion
      ;;
    q) rm ./yashandbSnap.cur ./yashandbSnap.pre
      exit
      ;;
    Q) rm ./yashandbSnap.cur ./yashandbSnap.pre
      exit
      ;;
    *)
      echo ""
      echo " d - Database overview"
      echo " D - Database detail"
      echo " b - Buffer pool"
      echo " s - Top SQL"
      echo "   z - Select orderby column"
      echo " l - List Locks & Spinlocks"
      echo " L - List Lockwaits"
      echo " S - List Sessions"
      echo " t - List Tablespaces"
      echo " T - List Tables"
      echo " w - List wait events"
      echo " m - List Memory Pool"
      echo " v - display version"
      echo " q - Quit"
      ;;
  esac
  read -t ${SLEEPINTERVAL} newKey 
  if [[ "${newKey}" != "" ]]; then
    preKey=${key}
    key=$newKey
  fi
  clear
  echo ""
done
