#!/bin/bash
#
#

function export_table()
{
  local user=$(echo ${DBURL}|awk -F/ '{print $1}')
  local password=$(echo ${DBURL}|awk -F/ '{print $2}'|awk -F@ '{print $1}')
  local dbServer=$(echo ${DBURL}|awk -F@ '{print $2}')

  local target_path=${output_path}/${table_owner}.${table_name}
  mkdir -p ${target_path}

  echo "  export ${partition_name} start:" $(date "+%F %T") >> ${LOGFILE}

  echo "exporting partition: ${partition_name}"
  exp --csv -u ${user} -p ${password} --server-host ${dbServer} -f csv -F ${target_path} -q "select * from ${table_owner}.${table_name}"

  echo "  export ${partition_name} end:  " $(date "+%F %T") >> ${LOGFILE}

  mv ${target_path}/outfile ${output_path}/${table_owner}.${table_name}.csv
  rm -fr ${target_path}
}

# Main

if [[ $# -lt 4 ]]; then
  echo Example: ${0} sys/yasdb_123@192.168.1.1:1688 table_owner table_name output_path
  exit 1
fi

DBURL=${1}
table_owner=$(echo ${2}|tr 'a-z' 'A-Z')
table_name=$(echo ${3}|tr 'a-z' 'A-Z')
output_path=$4

LOGFILE=${output_path}/${table_owner}.${table_name}.export.log

export_table
