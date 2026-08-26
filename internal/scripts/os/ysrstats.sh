#!/bin/bash
#
# 收集表，及该表上列、索引统计信息
# 限制：owner及table name 被转换为大写，名字中包含小写字母的不能收集
#

if [[ $# -lt 3 ]]; then
  echo Example: ${0} sys/yasdb_123@0.0.0.0:1688 owner tableName
  exit 1
fi

DBURL=${1}
owner=$(echo ${2}|tr 'a-z' 'A-Z')
tableName=$(echo ${3}|tr 'a-z' 'A-Z')
partName=$(echo ${4}|tr 'a-z' 'A-Z')

echo -e "Runstats on table ${owner}.${tableName} begin  at "`date "+%F %T"`
yasql ${DBURL} -c "EXEC DBMS_STATS.GATHER_TABLE_STATS('${owner}', '${tableName}', '${partName}', 0.2, FALSE, 'FOR ALL COLUMNS SIZE AUTO', 4, 'AUTO', TRUE)"
echo -e "Runstats on table ${owner}.${tableName} finish at "`date "+%F %T"`"\n"


