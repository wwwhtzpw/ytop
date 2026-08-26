#!/bin/bash
# 名称：get_sys_objects.sh
# 功能：目前YMP不支持SYS下面用户创建的对象迁移，而需要迁移的SCHEMA可能依赖这部分对象，不预先迁移这部分对象到YMP内置库及目标库，会影响兼容度评估
#       此脚本从ORACLE获取这些对象，每个对象生成两个文件 origin_${object_type}_${object_name}.pl target_${object_type}_${object_name}.pl
# 适配系统：Linux
# 运行身份：数据库用户, 依赖sqlplus
# 日志文件：
# 参数使用：./get_sys_objects.sh DBURL 
# 使用示例：./get_sys_objects.sh system/password@192.168.23.141:1521/orcl
# 版本：1.0
# 创建日期：2026-08-11
# 变动记录：

# 使用sqlplus执行SQL语句，输出结果到屏幕
function run_sql()
{
SQL="$*"
sqlplus -S ${DBURL} <<EOS
set echo off
set feedback off
set heading off
set trimspool on
set trimout on
set long 32768
SET LONGCHUNKSIZE 32768
set linesize 32767
set pagesize 0
set termout off
SET NEWPAGE 1
${SQL}
EOS
}

# Main

DBURL=${1:-system/password@192.168.23.141:1521/orcl}
OWNER=SYS

# Oracle 12C开始，dba_objects中增加字段ORACLE_MAINTAINED ，用于更精确地标记对象是否由 Oracle 维护。之前版本通过not like 粗略过滤系统对象

##run_sql "select object_type, object_name from dba_objects where owner='${OWNER}' and object_type in ('FUNCTION', 'PROCEDURE', 'PACKAGE', 'SYNONYM', 'TYPE') \
##	and object_name not like 'DBMS%' and object_name not like 'SYS%' and object_name not like '%$%' and object_name not like 'XML%' \
##	and object_name not like 'ORA%' and object_name not like 'DM%' and object_name not like 'OD%' and object_name not like 'UTL%' \
##	and object_name not like 'AWR%' and object_name not like 'PRVT%' and object_name not like 'SCHEDULER%' and object_name not like 'GEN%' \
##	and object_name not like 'WLM%' and object_name not like 'LOGMNR%' and object_name not like 'UNSIGN%' \
##        and object_name not like 'OWA%' and object_name not like 'OLAP%';" | grep -v Elapsed | while read object_type object_name

# Oracle 12C及之后版本使用下面命令
run_sql "select object_type, object_name from dba_objects where owner='${OWNER}' and object_type in ('FUNCTION', 'PROCEDURE', 'PACKAGE', 'SYNONYM', 'TYPE') \
         and oracle_maintained = 'N';" | grep -v Elapsed | while read object_type object_name
do
  echo ${object_type} ${object_name} 
  origin_file=origin_${object_type}_${object_name}.pl
  target_file=target_${object_type}_${object_name}.pl
  rm -f $origin_file
  run_sql "select dbms_metadata.get_ddl('${object_type}','${object_name}','${OWNER}') from dual;" >> ${origin_file}
  sed -i "/Elapsed/d"  ${origin_file}
  echo "/" >> ${origin_file}
  sed -i '/CREATE OR REPLACE PACKAGE BODY/i \/' ${origin_file}
  sed -i '/CREATE OR REPLACE TYPE BODY/i \/' ${origin_file}
  echo "grant execute on ${OWNER}.${object_name} to public;" >> ${origin_file}
  # 创建公共同义词，供用户SCHEMA调用SYS下面对象
  echo "CREATE PUBLIC SYNONYM ${object_name} FOR ${OWNER}.${object_name};" >> ${origin_file}
  cp ${origin_file} ${target_file}
done
