#!/bin/bash


hostList=192.168.24.166,192.168.24.168,192.168.24.170,192.168.24.172

# 配置免密互信

mkdir -p $HOME/.ssh
chmod -R 777 $HOME/.ssh

ssh-keygen -t rsa -f "$HOME/.ssh/id_rsa" -N ""

for host in `echo ${hostList}|awk -F, '{for(i=1;i<=NF;i++) print $i}'`
do
  ssh-copy-id $host
done

# 测试免密互信是否生效，应该显示主机名和当前时间，可比较服务器时间是否一致
for host in `echo ${hostList}|awk -F, '{for(i=1;i<=NF;i++) print $i}'`
do
  ssh $host "hostname; date"
done

