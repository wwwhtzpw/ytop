#!/bin/bash

if [[ $# -lt 3 ]]; then
  echo "Usage:   "$0 DBURL tableSchema.tableName csvFile
  echo "Example: "$0 DBURL sys/yasdb_123@0.0.0.0:1688 sys.t1 t1.csv
  exit 1
fi

DBURL=$1
tableSchema=$(echo $2|awk -F. '{print $1}'|tr 'a-z' 'A-Z')
tableName=$(echo $2|awk -F. '{print $2}'|tr 'a-z' 'A-Z')
dataFile=$3
replace=$(echo $4|tr 'a-z' 'A-Z')

loadControlFile=$(realpath ${dataFile}).ctl
badFile=$(realpath ${dataFile}).badfile

columnList=$(yasql ${DBURL} -c "SELECT '('||wm_concat(column_name)||')' FROM (select column_name from dba_tab_cols \
                   WHERE owner='${tableSchema}' AND table_name='${tableName}' ORDER BY column_id)" |sed "1,3 d"|head -1)

cat << EOF > $loadControlFile
LOAD DATA OPTIONS(COMMIT_ROWS=4096, NOLOGGING=FALSE, DEGREE_OF_PARALLELISM=16)
INFILE '${dataFile}' with embedded FIELDS TERMINATED BY '|' optionally enclosed by '"'
BADFILE '${badFile}'
INTO TABLE ${tableSchema}.${tableName}${columnList}
EOF

if [[ "${replace}" == "REPLACE" ]]; then
  yasql ${DBURL} -c "truncate table ${tableSchema}.${tableName}" > /dev/null
fi
yasldr ${DBURL} control_file=${loadControlFile}

rm ${loadControlFile}