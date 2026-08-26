#!/bin/bash
# 功能：从慢SQL日志中获取某sql_id的SQL语句传入参数值，将语句中的问号替换成实际值
#       慢SQL日志中SQL语句可能被截断，需要从SQL POOL中获取SQL语句全文，以及传入参数数据类型
# 适配系统：Linux
# 运行身份：数据库用户
# 日志文件：生成文件{sql_id}.slow.sql
# 参数使用：./gen_runable_slow_sql.sh sql_id slow.log DBURL
# 使用示例：./gen_runable_slow_sql.sh 7m2ryk1tgvx83 slow.log.20260323 sys/Cod-2020@10.172.0.33:1688
# 版本：1.0
# 更新日期：2026-03-25
# 变动记录：


# 从SQL POOL中获取sql_id对应SQL语句全文，以及传入参数类型，输出SQL模板文件、参数类型文件；不存在的话，直接使用慢SQL日志中的语句，参数类型未知
function get_sql_fulltext_and_parameter_datatype()
{
  local sql_id=$1
  local number_in_sqlpool
  
  number_in_sqlpool=$(${YASQL} -c "select count(*) from v\$sql where sql_id = '${sql_id}'" | sed -n '4p')
  if [[ ${number_in_sqlpool} -gt 0 ]]; then
    # SQL POOL 中存在sql_id对应SQL
    ${YASQL} -c "select sql_fulltext from v\$sql where sql_id = '${sql_id}' limit 1" > ${SQL_TEMPLETE}
    sed -i '1,3 d' ${SQL_TEMPLETE}
    sed -i 's/1 row.*/;/' ${SQL_TEMPLETE}

    ${YASQL} -c "select distinct 'filter', datatype_string, position from v\$sql_bind_capture where sql_id='${sql_id}' and last_captured is not null order by position" | grep filter | awk '{print $2}' > ${BIND_DATATYPE}
  else
    # SQL POOL 中不存在sql_id对应SQL，直接使用慢SQL日志中捕获的SQL语句，有可能被截断
    sed -n "/${sql_id}/,/BindParameters:/ p" ${SLOW_LOG_FILE} | head -1000 | sed -n '1,/Bind/ p' | sed '/# SQL_ID:/ d' | sed 's/BindParameters:.*/;/' | sed 's/SQL://' > ${SQL_TEMPLETE}
    touch ${BIND_DATATYPE}
  fi
}
  
#  用实际传入值替换SQL语句中的?
function replace_question_mark_with_value()
{
  local value_list=$*
  
  local position=1
  local datatype

  cat ${SQL_TEMPLETE} > tmp.sql
  echo ${value_list} | awk -F',' '{for (i=1; i<=NF; i++) print $i}'  | while read value
  do  
    datatype=$(sed -n "${position} p" ${BIND_DATATYPE})
    # DATE TIMESTAMP 数据类型传入参数需要特别处理
    if [[ "${datatype}" = "DATE" ]]; then
      value=to_date"('${value}')"
    elif [[ "${datatype}" = "TIMESTAMP" ]]; then
      value=to_timestamp"('${value}')"
    fi
    sed -i "1,/?/ s/?/$value/" tmp.sql
    position=$((position+1))
  done

  cat tmp.sql; rm tmp.sql
}

# Main

if [[ $# -ne 3 ]]; then
  echo Usage: $(basename $0) sql_id slow.log DBURL
  exit
fi

sql_id=$1
SLOW_LOG_FILE=$2
DBURL=$3

YASQL="yasql ${DBURL}"

SQL_TEMPLETE=${sql_id}.templete
BIND_DATATYPE=${sql_id}.datatype
SLOW_SQL=${sql_id}.slow.sql

get_sql_fulltext_and_parameter_datatype ${sql_id}

sed -n "/${sql_id}/,/^# TIME:/p" ${SLOW_LOG_FILE} | grep BindParameters | sed 's/BindParameters://' > ${sql_id}.bindlist

if [ ! -s ${sql_id}.bindlist ]; then
  # 慢SQL没有传入参数，直接获取慢SQL日志中的语句
  cp ${SQL_TEMPLETE} ${SLOW_SQL}
else
  while read line; do
    replace_question_mark_with_value $line | tee -a ${SLOW_SQL}
  done < ${sql_id}.bindlist
fi

rm ${sql_id}.bindlist ${SQL_TEMPLETE} ${BIND_DATATYPE}
