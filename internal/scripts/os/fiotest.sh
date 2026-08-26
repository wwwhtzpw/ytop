#! /bin/bash
cat << EOF
EOF

#单线程4K文件测试大小4G
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=4k -size=4G -group_reporting -rw=randread  -name=1-4k-randread -runtime=30 >> /data/1process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=4k -size=4G -group_reporting -rw=randwrite  -name=1-4k-randwrite -runtime=30 >> /data/1process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=4k -size=4G -group_reporting -rw=read  -name=1-4k-read -runtime=30 >> /data/1process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=4k -size=4G -group_reporting -rw=write  -name=1-4k-write -runtime=30 >> /data/1process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=4k -rwmixread=70  -size=4G -group_reporting -rw=randrw  -name=1-4k-randrw -runtime=30 >> /data/result/1process_4k

#单线程64K文件测试大小4G
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=64k -size=4G -group_reporting -rw=randread  -name=1-64k-randread >> /data/1process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=64k -size=4G -group_reporting -rw=randwrite  -name=1-64k-randwrite >> /data/1process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=64k -size=4G -group_reporting -rw=read  -name=1-64k-read -runtime=30 >> /data/1process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=64k -size=4G -group_reporting -rw=write  -name=1-64k-write -runtime=30 >> /data/1process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1 -bs=64k -rwmixread=70  -size=4G -group_reporting -rw=randrw  -name=1-64k-randrw -runtime=30 >> /data/result/1process_64k

#单线程512k文件测试大小4G
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1   -bs=512k -size=4G -group_reporting -rw=randread  -name=1-512k-randread -runtime=30 >> /data/1process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1   -bs=512k -size=4G -group_reporting -rw=randwrite  -name=1-512k-randwrite -runtime=30 >> /data/1process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1   -bs=512k -size=4G -group_reporting -rw=read  -name=1-512k-read -runtime=30 >> /data/1process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1   -bs=512k -size=4G -group_reporting -rw=write  -name=1-512k-write -runtime=30 >> /data/1process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=1   -bs=512k -rwmixread=70 -size=4G -group_reporting -rw=randrw  -name=1-512k-randrw -runtime=30 >> /data/result/1process_512k

#8线程4k文件测试大小4G
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=4k -size=4G -group_reporting -rw=randread  -name=8-4k-randread -runtime=30 >> /data/8process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=4k -size=4G -group_reporting -rw=randwrite  -name=8-4k-randwrite -runtime=30 >> /data/8process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=4k -size=4G -group_reporting -rw=read  -name=8-4k-read -runtime=30 >> /data/8process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=4k -size=4G -group_reporting -rw=write  -name=8-4k-write -runtime=30 >> /data/8process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=4k  -rwmixread=70 -size=4G -group_reporting -rw=randrw  -name=8-4k-randrw -runtime=30 >> /data/result/8process_4k

#8线程64K文件测试大小4G
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=64k -size=4G -group_reporting -rw=randread  -name=8-64k-randread -runtime=30 >> /data/8process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=64k -size=4G -group_reporting -rw=randwrite  -name=8-64k-randwrite -runtime=30 >> /data/8process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=64k -size=4G -group_reporting -rw=read  -name=8-64k-read -runtime=30 >> /data/8process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=64k -size=4G -group_reporting -rw=write  -name=8-64k-write -runtime=30 >> /data/8process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=64k  -rwmixread=70 -size=4G -group_reporting -rw=randrw  -name=8-64k-randrw -runtime=30 >> /data/result/8process_64k

#8线程512k文件测试大小4G
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=512k -size=4G -group_reporting -rw=randread  -name=8-512k-randread  -runtime=30 >> /data/8process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=512k -size=4G -group_reporting -rw=randwrite  -name=8-512k-randwrite  -runtime=30 >> /data/8process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=512k -size=4G -group_reporting -rw=read  -name=8-512k-read -runtime=30 >> /data/8process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=512k -size=4G -group_reporting -rw=write  -name=8-512k-write -runtime=30 >> /data/8process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=8   -bs=512k -rwmixread=70 -size=4G -group_reporting -rw=randrw  -name=8-512k-randrw -runtime=30 >> /data/result/8process_512k

#16线程4k文件测试大小4G
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=4k -size=4G -group_reporting -rw=randread  -name=16-4k-randread -runtime=30 >> /data/16process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=4k -size=4G -group_reporting -rw=randwrite  -name=16-4k-randwrite -runtime=30 >> /data/16process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=4k -size=4G -group_reporting -rw=read  -name=16-4k-read -runtime=30 >> /data/16process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=4k -size=4G -group_reporting -rw=write  -name=16-4k-write -runtime=30 >> /data/16process_4k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=4k -rwmixread=70 -size=4G -group_reporting -rw=randrw  -name=16-4k-randrw -runtime=30 >> /data/result/16process_4k

fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=64k -size=4G -group_reporting -rw=randread  -name=16-64k-randread -runtime=30 >> /data/16process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=64k -size=4G -group_reporting -rw=randwrite  -name=16-64k-randwrite -runtime=30 >> /data/16process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=64k -size=4G -group_reporting -rw=read  -name=16-64k-read -runtime=30 >> /data/16process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=64k -size=4G -group_reporting -rw=write  -name=16-64k-write -runtime=30 >> /data/16process_64k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=64k -rwmixread=70 -size=4G -group_reporting -rw=randrw  -name=16-64k-randrw -runtime=30 >> /data/result/16process_64k

fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=512k -size=4G -group_reporting -rw=randread  -name=16-512k-randread -runtime=30 >> /data/16process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=512k -size=4G -group_reporting -rw=randwrite  -name=16-512k-randwrite -runtime=30 >> /data/16process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=512k -size=4G -group_reporting -rw=read  -name=16-512k-read -runtime=30 >> /data/16process_512k
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=512k -size=4G -group_reporting -rw=write  -name=16-512k-write -runtime=30 >> /data/16process_512k           
fio -directory=/data/demo1 -direct=1 -iodepth=4 -thread -ioengine=libaio -numjobs=16   -bs=512k -rwmixread=70 -size=4G -group_reporting -rw=randrw  -name=16-512k-randrw -runtime=30 >> /data/result/16process_512k
