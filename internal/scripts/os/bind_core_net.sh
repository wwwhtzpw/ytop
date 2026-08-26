#!/bin/bash
# 
# 网卡中断绑核脚本, 自动检查NUMA节点数量以及网卡对应的中断号，从每个NUMA节点的第一个核开始绑起
# 用法：./bind_core_net.sh 网卡设备名 每个NUMA节点绑核数量
# 示例：./bind_core_net.sh enp1s0f0 2
# 

# 查找网卡对应的第一个中断号, 假定后面中断号是连续的
function getFirstIrq()
{
  local adapter=$1
  local device=$(ls -l /sys/class/net/${adapter}|awk -F/ '{print $(NF-2)}')
  echo $(ls /sys/bus/pci/devices/${device}/msi_irqs|awk '{print $1}'|head -1)  
}

#
# Main
# 

if [[ $# -lt 3 ]]; then
  echo $0 ethernetAdapter \"nodelist\" coresPerNode
  echo -e "\n例: 网卡enp4s0f0中断绑定到NUMA NODE 0 上，每个NODE绑16个核"
  echo $0 enp4s0f0 0 16
  echo -e "\n例: 网卡enp4s0f1中断绑定到NUMA NODE 1 2 3上，每个NODE绑4个核"
  echo $0 enp4s0f1 \"1 2 3\" 4
  exit 1
fi
ethernetAdapter=$1
nodeList=${2}
corePerNode=${3:-1}

# 避免中文环境lscpu命令输出问题
export LC_ALL=en_US.UTF-8

numaNodes=$(echo ${nodeList} | wc -w)
combinedQueues=$((numaNodes * corePerNode))

# 停止并禁止 irqbalance
systemctl stop irqbalance
systemctl disable irqbalance

# 更改网卡中断队列数量, 列出更改前后的配置信息
ethtool -l ${ethernetAdapter}
ethtool -L ${ethernetAdapter} combined ${combinedQueues}
ethtool -l ${ethernetAdapter}

# 更改网卡属性，转移一些CPU工作负载到网卡处理，有些特性可能网卡不支持
ethtool -K ${ethernetAdapter} tso on
ethtool -K ${ethernetAdapter} lro on
ethtool -K ${ethernetAdapter} gro on
ethtool -K ${ethernetAdapter} gso on

# 获取网卡设备对应的第一个中断号，假定后面中断号累加1
firstIrq=$(getFirstIrq ${ethernetAdapter})
irq=${firstIrq}

for node in ${nodeList}
do
  coreList=$(numactl --hardware | grep "node $node cpus"| awk -F: '{print $2}')
  echo coreList:$coreList
  i=0
  for core in ${coreList}
  do
    if [[ $i -ge ${corePerNode} ]]; then
      break
    else
      echo " Core number:"${core}
      echo "${core}" > /proc/irq/${irq}/smp_affinity_list
      echo "Result:"
      cat /proc/irq/${irq}/effective_affinity*
      irq=$((irq+1))
      i=$((i+1))
    fi
  done
done
