#!/bin/bash
# 名称：gen_sqlmap.sh
# 功能：生成某sql_id的语句SQLMAP创建模板，模板包括原始语句、映射语句，可修改映射语句后，运行这个命令创建SQLMAP
# 适配系统：Linux
# 运行身份：数据库用户
# 日志文件：生成文件map_{sql_id}.sql
# 参数使用：./gen_sqlmap.sh sql_id DBURL
# 使用示例：./gen_sqlmap.sh 7m2ryk1tgvx83 sys/Cod-2022@192.168.23.81:1688
# 创建日期：2026-03-25

if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename $0) sql_id DBURL"
  exit
fi

sql_id=${1}
# 第二传入参数数据库连接串，如不想在命令行输入URL信息，可更改默认配置
DBURL=${2:-sys/Cod-2022}

sqlmap_name=map_${sql_id}
sqlmap_file=${sqlmap_name}.sql

yasql ${DBURL} -c "select 'create sqlmap ${sqlmap_name} (all, ' || chr(10) || '  -- Original SQL' || chr(10) || '  ''' || replace(sql_fulltext,'''','''''') || ''',' || chr(10) || '  -- Mapped SQL' || chr(10) || '  ''' || replace(sql_fulltext,'''','''''') || ''');' from v\$sql where sql_id='${sql_id}' limit 1" | tee ${sqlmap_file}

# 删除输出结果中多余信息
sed -i '1,3 d' ${sqlmap_file}
sed -i '$ d' ${sqlmap_file}
sed -i '$ d' ${sqlmap_file}

# 增加注释信息
sed -i "1i -- 打开开关" ${sqlmap_file}
sed -i "1a alter system set _SQL_MAP=true;" ${sqlmap_file}
sed -i '2a\\' ${sqlmap_file}

sed -i "3a drop sqlmap ${sqlmap_name};" ${sqlmap_file}
