#!/bin/bash
#
# 生成更新统计信息的DBMS_STATS.SET_XXX_STATS调用语句，可用来保存表的统计信息版本
#
# 限制：owner及table name 被转换为大写，名字中包含小写字母不能生成相应语句
#       在YashanDB 23.2 版本适用，其它版本有可能不能正常工作
#

if [[ $# -lt 3 ]]; then
  echo Example: ${0} sys/yasdb_123@0.0.0.0:1688 owner tableName
  exit 1
fi

DBURL=${1}
owner=$(echo ${2}|tr 'a-z' 'A-Z')
tableName=$(echo ${3}|tr 'a-z' 'A-Z')

# 表统计信息
echo "-- Update statistics for table ${owner}.${tableName}"
yasql ${DBURL} -c "SELECT 'EXEC DBMS_STATS.SET_TABLE_STATS('''||owner||''','''||table_name||''','''||partition_name||''',' \
  ||num_rows||','||blocks||','||avg_row_len||');' FROM dba_tab_statistics WHERE owner='${owner}' AND table_name='${tableName}' AND partition_name IS NULL" \
  |grep ${owner}
echo ""

# 索引统计信息
yasql ${DBURL} -c "SELECT 'EXEC DBMS_STATS.SET_INDEX_STATS('''||owner||''','''||index_name||''','''||partition_name||''',' \
  ||num_rows||','||leaf_blocks||','||distinct_keys||','||distinct_fkeys||','||avg_leaf_blocks_per_key||','||avg_data_blocks_per_key \
  ||','||clustering_factor||','||blevel||');' \
  FROM dba_ind_statistics WHERE owner='${owner}' AND table_name='${tableName}' AND partition_name IS NULL" \
  |grep ${owner}
echo ""

# 列统计信息
yasql ${DBURL} -c "SELECT 'EXEC DBMS_STATS.SET_COLUMN_STATS('''||owner||''','''||table_name||''','''||column_name||''','||''''',' \
  ||num_distinct||','||density||','||num_nulls||','||avg_col_len||');' \
  FROM dba_tab_col_statistics WHERE owner='${owner}' AND table_name='${tableName}' "  \
  |grep ${owner}
echo ""
