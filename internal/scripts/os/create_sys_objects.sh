#!/bin/bash
# 在目标库创建SYS下面的用户对象

ymp_bashrc=$(find ~ -name "ymp.bashrc")
source ${ymp_bashrc}

alias ys='yasql / as sysdba'
#alias ys='yasql sys/Cod-2022@10.203.28.141:1688'
for type in TYPE FUNCTION PACKAGE PROCEDURE; do
  for file in $(ls target_${type}_*.pl); do
    ys -f -e $file | tee $file.log
  done
done
