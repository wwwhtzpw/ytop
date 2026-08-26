#!/bin/bash
# 名称：get_explain.sh
# 功能：根据sql_id或plan_hash_value获取SQL语句在内存中的执行计划，如果传入参数是sql_id则获取该sql_id对应的第一个plan_hash_value的执行计划
#       生成{sql_id}_{plan_hash_value}.xxx 共5个文件，xxx分别为sql 语句, snap 语句运行快照, explain 执行计划, ddl 表、索引、视图定义, stats 统计信息
#       最后打包成{sql_id}_{plan_hash_value}.tar.gz文件
# 适配系统：Linux
# 运行身份：数据库用户，有dba_tab_statistics等表的访问权限
# 日志文件：
# 参数使用：./get_explain.sh DBURL plan_hash_value|sql_id
# 使用示例：./get_explain.sh tpcc/tpcc@192.168.23.81:1688 3478631816
# 版本：1.1
# 创建日期：2026-06-16
# 变动记录：2026-06-17 执行计划中只用到索引，无法从v$sql_plan获取对应表名，通过dba_indexes找到索引对应的表名

# 调用yasql执行SQL语句, 每次调用产生一次数据库连接/断开
function execute_sql()
{
  yasql ${DBURL} -c "$*"
}

# 创建UDF-REPEAT, 格式化执行计划输出，方便阅读
function create_udf_repeat()
{
  execute_sql "CREATE OR REPLACE FUNCTION repeat(p_str VARCHAR, p_repeat INT) RETURN VARCHAR
    IS v_str VARCHAR(1000);
    BEGIN
      v_str := '';
      IF p_repeat > 0 THEN
        FOR i in 1..p_repeat
        LOOP
          v_str := v_str || p_str;
        END LOOP;
      END IF;
      RETURN v_str;
    END;
    "
}


# 获取表相关统计信息
function get_stats()
{
  local owner=$(echo ${1}|tr 'a-z' 'A-Z')
  local tableName=$(echo ${2}|tr 'a-z' 'A-Z')

  # 表统计信息
  echo "-- Update statistics for table ${owner}.${tableName}"
  execute_sql "SELECT '-- Last analyzed date: ' || last_analyzed FROM dba_tab_statistics WHERE owner='${owner}' AND table_name='${tableName}' limit 1"  | grep Last
  execute_sql "SELECT 'EXEC DBMS_STATS.SET_TABLE_STATS('''||owner||''','''||table_name||''','''||partition_name||''',' \
    ||num_rows||','||blocks||','||avg_row_len||');' FROM dba_tab_statistics WHERE owner='${owner}' AND table_name='${tableName}' AND partition_name IS NULL" \
    |grep ${owner}
  echo ""
  
  # 索引统计信息
  execute_sql "SELECT 'EXEC DBMS_STATS.SET_INDEX_STATS('''||owner||''','''||index_name||''','''||partition_name||''',' \
    ||num_rows||','||leaf_blocks||','||distinct_keys||','||distinct_fkeys||','||avg_leaf_blocks_per_key||','||avg_data_blocks_per_key \
    ||','||clustering_factor||','||blevel||','||distinct_2keys||','||distinct_3keys||','||distinct_4keys||');' \
    FROM dba_ind_statistics WHERE owner='${owner}' AND table_name='${tableName}' AND partition_name IS NULL" \
    |grep ${owner}
  echo ""
  
  # 列统计信息
  execute_sql "SELECT 'EXEC DBMS_STATS.SET_COLUMN_STATS('''||owner||''','''||table_name||''','''||column_name||''','||''''',' \
    ||num_distinct||','||density||','||num_nulls||','||avg_col_len||');' \
    FROM dba_tab_col_statistics WHERE owner='${owner}' AND table_name='${tableName}' "  \
    |grep ${owner}
  echo ""
}
 

# Generate CREATE TABLE statements
function get_table_ddl()
{
  local tableOwner=$1
  local tableName=$2
  local text

  echo "-- DDL for TABLE ${tableOwner}.${tableName} "
  text=$(execute_sql "SELECT to_char(dbms_metadata.get_ddl('table','${tableName}','${tableOwner}')) FROM dual" \
    |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d')
  echo -e "${text};\n" 
}

# Get column name and descend for an index
function getIndexColumns()
{
  local indexOwner=$1
  local indexName=$2
  local tablespaceName=$3

  execute_sql "SELECT column_name,descend FROM dba_ind_columns WHERE index_owner='${indexOwner}' AND index_name='${indexName}' ORDER BY column_position"\
    |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d'| \
  while read columnName descend
  do
    echo -ne "\n    "\"${columnName}\"" "${descend},
  done
  echo -e ") TABLESPACE ${tablespaceName} \n"
}

# Generate "CREATE INDEX" statement, using default values, some information lost.
function get_index_ddl()
{
  local tableOwner=$1
  local tableName=$2
  local indexOwner
  local indexName
  local uniqueness 
  local tablespaceName
  local unique
  local ifExist=1
  local initTrans=2
  local maxTrans=255
  local pctfree=8
  local partitioned
  
  execute_sql "SELECT owner, index_name, uniqueness, tablespace_name, ini_trans, max_trans, pct_free, partitioned FROM dba_indexes WHERE table_owner='${tableOwner}' AND table_name='${tableName}' and GENERATED='N'" \
    |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d'| \
  while read indexOwner indexName uniqueness tablespaceName initTrans maxTrans pctfree partitioned
  do
    if [ ${ifExist} -eq 1 ]; then
      echo "-- CREATE INDEXES FOR TABLE ${tableOwner}.${tableName} "
      ifExist=0
    fi
    if [[ "${uniqueness}" == "Y" ]]; then
      unique=UNIQUE
    else
      unique=""
    fi
    echo -ne "CREATE ${unique} INDEX \"${indexOwner}\".\"${indexName}\" ON \"${tableOwner}\".\"${tableName}\" ("
    indexColumns=$(getIndexColumns ${indexOwner} ${indexName} ${tablespaceName}) 
    echo -ne ${indexColumns}|sed 's/,)/)/'
    if [[ "${partitioned}" == "Y" ]]; then
      echo -ne " LOCAL"
    else
      echo -ne " GLOBAL"
    fi
    echo " PCTFREE ${pctfree} INITRANS ${initTrans} MAXTRANS ${maxTrans};"
  done
  echo ""
 } 

# Generate "CREATE VIEW" statement
function get_view()
{
  local tableOwner=$1
  local tableName=$2
  local viewOwner
  local viewName
  local text
  local ifExist=1

  execute_sql "SELECT owner, name FROM dba_dependencies WHERE referenced_owner='${tableOwner}' AND referenced_name='${tableName}' AND type='VIEW'" \
    |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d'| \
  while read viewOwner viewName
  do
    if [ ${ifExist} -eq 1 ]; then
      echo "-- CREATE VIEW FOR TABLE ${tableOwner}.${tableName} "
      ifExist=0
    fi
    text=$(execute_sql "SELECT text||';' FROM dba_views WHERE owner='${viewOwner}' AND view_name='${viewName}'" \
      |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d')
    echo "CREATE VIEW ${viewOwner}.${viewName} AS ${text}"
    getTableComment ${viewOwner} ${viewName} 
    echo ""
  done
}

#
# Main
#

if [[ $# -lt 2 ]]; then
  echo "$0 DBURL plan_hash_value|sql_id"
  exit 1
fi

DBURL=${1}

if [[ $2 -gt 0 ]] 2>/dev/null; then
  plan_hash_value=${2}
else
  plan_hash_value=$(execute_sql "SELECT 'hash ' ||plan_hash_value as plan_hash_value FROM v\$sql WHERE sql_id='${2}'" | sed -n '4 p' | awk '{print $2}')
fi

output_file=$(execute_sql "SELECT rtrim(sql_id || '_' || plan_hash_value) FROM v\$sql WHERE plan_hash_value=${plan_hash_value} limit 1" | sed -n '4 p')
if [[ "${output_file}" = "" ]]; then
  echo "sql_id or plan_hash_value: $2 does not exist in v\$sql"
  exit
fi

# 检查UDF-REPEAT是否已存在，不存在则创建
if_exist=$(execute_sql "SELECT 'UDF ' || count(*) AS result FROM user_objects WHERE object_type='UDF' AND object_name='REPEAT'" | grep UDF | awk '{print $2}')
if [[ ${if_exist} -eq 0 ]]; then
  create_udf_repeat
fi

output_file=$(echo ${output_file})

# 清空文件
for ext in sql snap explain ddl stats; do
  rm -f ${output_file}.${ext}
done

execute_sql "SELECT sql_fulltext FROM v\$sql WHERE plan_hash_value = ${plan_hash_value}" | sed -n '4,$ p' | sed '/1 row/d' > ${output_file}.sql
echo ";" >> ${output_file}.sql

execute_sql "SELECT executions, cpu_time, cpu_time/executions, elapsed_time, disk_reads, disk_reads/executions, buffer_gets, buffer_gets/executions FROM v\$sql WHERE plan_hash_value = ${plan_hash_value}" > ${output_file}.snap

execute_sql "SELECT distinct id, repeat('||', depth) || operation as operation, object_name FROM v\$sql_plan WHERE plan_hash_value = ${plan_hash_value} AND id IS NOT NULL ORDER BY id" > ${output_file}.explain

execute_sql "SELECT object_owner, object_name, 'filter' FROM v\$sql_plan WHERE object_type='TABLE' and  plan_hash_value = ${plan_hash_value} \
   UNION SELECT table_owner, table_name, 'filter' FROM dba_indexes \
           WHERE (owner, index_name) IN (SELECT object_owner, object_name FROM v\$sql_plan WHERE plan_hash_value = ${plan_hash_value})"  | grep filter  | while read owner table_name other

do
  get_table_ddl ${owner} ${table_name}  >> ${output_file}.ddl
  get_index_ddl ${owner} ${table_name}  >> ${output_file}.ddl
  get_view ${owner} ${table_name}  >> ${output_file}.ddl

  get_stats $owner $table_name >> ${output_file}.stats
done
tar czvf ${output_file}.tar.gz ${output_file}.*
