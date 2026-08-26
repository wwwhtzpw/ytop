#!/bin/bash
################################################################################
# Description:
#   Get table ddl including CREATE TABLE, COMMENTS, CREATE INDEX, CREATE VIEW
#
# Example:
#   ./yslook.sh sys/yasdb_123@0.0.0.0:1688 SYS T1
#
# Written by: Zhang Limin                                            2023-06-06
################################################################################

# Generate CREATE TABLE statements
function getTableDDL()
{
  local tableOwner=$1
  local tableName=$2
  local text

  #echo "-- CREATE TABLE ${tableOwner}.${tableName} "
  text=$(yasql ${DBURL} -c "SELECT to_char(dbms_metadata.get_ddl('table','${tableName}','${tableOwner}')) FROM dual" \
    |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d')
  echo -e "${text};\n" 
}

# Get column name and descend for an index
function getIndexColumns()
{
  local indexOwner=$1
  local indexName=$2
  local tablespaceName=$3

  yasql ${DBURL} -c "SELECT column_name,descend FROM dba_ind_columns WHERE index_owner='${indexOwner}' AND index_name='${indexName}' ORDER BY column_position"\
    |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d'| \
  while read columnName descend
  do
    echo -ne "\n    "\"${columnName}\"" "${descend},
  done
  echo -e ") TABLESPACE ${tablespaceName} \n"
}

# Generate "CREATE INDEX" statement, using default values, some information lost.
function getIndexDDL()
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
  
  yasql ${DBURL} -c "SELECT owner, index_name, uniqueness, tablespace_name, ini_trans, max_trans, pct_free, partitioned FROM dba_indexes WHERE table_owner='${tableOwner}' AND table_name='${tableName}' and GENERATED='N'" \
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
function getView()
{
  local tableOwner=$1
  local tableName=$2
  local viewOwner
  local viewName
  local text
  local ifExist=1

  yasql ${DBURL} -c "SELECT owner, name FROM dba_dependencies WHERE referenced_owner='${tableOwner}' AND referenced_name='${tableName}' AND type='VIEW'" \
    |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d'| \
  while read viewOwner viewName
  do
    if [ ${ifExist} -eq 1 ]; then
      echo "-- CREATE VIEW FOR TABLE ${tableOwner}.${tableName} "
      ifExist=0
    fi
    text=$(yasql ${DBURL} -c "SELECT text||';' FROM dba_views WHERE owner='${viewOwner}' AND view_name='${viewName}'" \
      |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d')
    echo "CREATE VIEW ${viewOwner}.${viewName} AS ${text}"
    getTableComment ${viewOwner} ${viewName} 
    echo ""
  done
}

# Get table comment
function getTableComment()
{
  local tableOwner=$1
  local tableName=$2
  local text

  text=$(yasql ${DBURL} -c "SELECT ''''||comments||'''' FROM dba_tab_comments WHERE owner='${tableOwner}' AND table_name='${tableName}' AND comments IS NOT NULL" \
    |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d')

  if [[ "${text}" != "" ]]; then
    echo -e "COMMENT ON TABLE ${tableOwner}.${tableName} IS ${text};\n"
  fi
}

# Get column comment
function getColumnComment()
{
  local tableOwner=$1
  local tableName=$2
  local columnName
  local comment

  yasql ${DBURL} -c "SELECT column_name, ''''||comments||'''' FROM dba_col_comments WHERE owner='${tableOwner}' AND table_name='${tableName}' AND comments IS NOT NULL" \
    |sed '1,3 d'|sed '1!G;h;$!d'|sed '1,3 d'|sed '1!G;h;$!d' \
  |while read columnName comment
  do
    echo "COMMENT ON COLUMN ${tableOwner}.${tableName}.${columnName} IS ${comment};"
  done
  echo ""
}

# Main

if [[ $# -ne 3 ]]; then
  echo "Example:$0 sys/yasdb_123@0.0.0.0:1688 SYS T1"
  exit 1
fi

DBURL=${1:-sys/yasdb_123@0.0.0.0:1688}
tableOwner=$(echo $2|tr 'a-z' 'A-Z')
tableName=$(echo $3|tr 'a-z' 'A-Z')

echo ---------- DDL for Table ${tableOwner}.${tableName} ----------
getTableDDL ${tableOwner} ${tableName} 
#getTableComment ${tableOwner} ${tableName} 
#getColumnComment ${tableOwner} ${tableName} 
getIndexDDL ${tableOwner} ${tableName} 
getView ${tableOwner} ${tableName} 

