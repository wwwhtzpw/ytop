YCM_INSTALL_PATH=/opt/ycm
$YCM_INSTALL_PATH/ycm/monit/monitctl start
$YCM_INSTALL_PATH/ycm/monit/monitctl run start -g ycm
$YCM_INSTALL_PATH/ycm/monit/monitctl run start -g prometheus
$YCM_INSTALL_PATH/ycm/monit/monitctl run start -g loki
$YCM_INSTALL_PATH/ycm/monit/monitctl run start -g promtail
$YCM_INSTALL_PATH/ycm/monit/monitctl run start -g yashandb_exporter
# 启动YCM AGENT
$YCM_INSTALL_PATH/ycm-agent/monit/monitctl start
$YCM_INSTALL_PATH/ycm-agent/monit/monitctl run start -g ycm-agent
$YCM_INSTALL_PATH/ycm-agent/monit/monitctl run start -g node_exporter
$YCM_INSTALL_PATH/ycm-agent/monit/monitctl run start -g promtail
