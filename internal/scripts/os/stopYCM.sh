YCM_INSTALL_PATH=/opt/ycm
$YCM_INSTALL_PATH/ycm/monit/monitctl stop
$YCM_INSTALL_PATH/ycm/monit/monitctl run stop -g ycm
$YCM_INSTALL_PATH/ycm/monit/monitctl run stop -g prometheus
$YCM_INSTALL_PATH/ycm/monit/monitctl run stop -g loki
$YCM_INSTALL_PATH/ycm/monit/monitctl run stop -g promtail
$YCM_INSTALL_PATH/ycm/monit/monitctl run stop -g yashandb_exporter
# 启动YCM AGENT
$YCM_INSTALL_PATH/ycm-agent/monit/monitctl stop
$YCM_INSTALL_PATH/ycm-agent/monit/monitctl run stop -g ycm-agent
$YCM_INSTALL_PATH/ycm-agent/monit/monitctl run stop -g node_exporter
$YCM_INSTALL_PATH/ycm-agent/monit/monitctl run stop -g promtail
