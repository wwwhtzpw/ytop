#!/usr/bin/env bash
# 兼容 /bin/sh 执行，避免使用非 POSIX 选项
set -eu

############################################
# 固定文件位置（按需修改）
############################################
JDK_TAR="/root/jdk-8u361-linux-x64.tar.gz"
BENCH_ZIP="/root/benchmarksql-5.0.zip"
JDBC_JAR_SRC="/root/yashandb-jdbc-1.9.3.jar"

############################################
# 安装目标路径（按需修改）
############################################
JDK_INSTALL_DIR="/usr/local/jdk1.8.0_361"
JAVA_HOME="${JAVA_HOME:-${JDK_INSTALL_DIR}}"

TPC_ROOT="${TPC_ROOT:-/home/yashan/tpcc}"
BENCH_HOME="${BENCH_HOME:-${TPC_ROOT}/benchmarksql-5.0}"
JDBC_DIR_TARGET="${BENCH_HOME}/lib/yashandb"

# 数据库连接参数（可按需调整或用环境变量覆盖）
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-1688}"
DB_NAME="${DB_NAME:-yashandb}"
DB_USER="${DB_USER:-sys}"
DB_PASS="${DB_PASS:-sys}"

# TPC-C 业务参数
WAREHOUSES="${WAREHOUSES:-10}"
LOAD_WORKERS="${LOAD_WORKERS:-2}"
TERMINALS="${TERMINALS:-10}"
RUN_MINS="${RUN_MINS:-5}"

############################################
# 通用函数
############################################
log() { echo "[$(date +'%F %T')] $*"; }
die() { echo "[$(date +'%F %T')] ERROR: $*" >&2; exit 1; }

############################################
# 安装 / 配置 JDK 8
############################################
install_jdk() {
  log "准备安装 JDK..."

  [ -f "${JDK_TAR}" ] || die "未找到 ${JDK_TAR}"

  if [ -d "${JDK_INSTALL_DIR}" ]; then
    log "JDK 目录已存在：${JDK_INSTALL_DIR}，跳过解压。"
  else
    mkdir -p "$(dirname "${JDK_INSTALL_DIR}")"
    tar -xf "${JDK_TAR}" -C "$(dirname "${JDK_INSTALL_DIR}")"
    # Oracle JDK 解压后目录名通常类似 jdk1.8.0_361，这里统一成 JDK_INSTALL_DIR
    real_dir=$(tar -tf "${JDK_TAR}" | head -n1 | cut -d/ -f1)
    if [ "${real_dir}" != "$(basename "${JDK_INSTALL_DIR}")" ]; then
      mv "$(dirname "${JDK_INSTALL_DIR}")/${real_dir}" "${JDK_INSTALL_DIR}"
    fi
    log "JDK 已解压至 ${JDK_INSTALL_DIR}"
  fi

  export JAVA_HOME="${JDK_INSTALL_DIR}"
  export PATH="${JAVA_HOME}/bin:${PATH}"

  log "JAVA_HOME=${JAVA_HOME}"
  command -v java  >/dev/null 2>&1 || die "java 未在 PATH 中，请检查 JDK 安装。"
  command -v javac >/dev/null 2>&1 || die "javac 未在 PATH 中，请检查 JDK 安装。"
}

############################################
# 基础环境检查
############################################
check_basic_tools() {
  log "检查 ant 和 unzip（如不存在则自动通过 yum 安装）..."

  if ! command -v ant >/dev/null 2>&1; then
    if command -v yum >/dev/null 2>&1; then
      log "未找到 ant，尝试执行: yum install -y ant"
      yum install -y ant || die "yum 安装 ant 失败，请手动检查。"
    else
      die "未找到 ant，且系统无 yum，请手动安装 ant。"
    fi
  fi

  if ! command -v unzip >/dev/null 2>&1; then
    if command -v yum >/dev/null 2>&1; then
      log "未找到 unzip，尝试执行: yum install -y unzip"
      yum install -y unzip || die "yum 安装 unzip 失败，请手动检查。"
    else
      die "未找到 unzip，且系统无 yum，请手动安装 unzip。"
    fi
  fi

  mkdir -p "${TPC_ROOT}"

  [ -n "${DB_HOST}" ] || die "DB_HOST 不能为空"
  [ -n "${DB_PORT}" ] || die "DB_PORT 不能为空"
  [ -n "${DB_NAME}" ] || die "DB_NAME 不能为空"
  [ -n "${DB_USER}" ] || die "DB_USER 不能为空"
  [ -n "${DB_PASS}" ] || die "DB_PASS 不能为空"
}

############################################
# 解压 BenchmarkSQL（使用 jar xf）
############################################
prepare_benchmarksql() {
  if [ -d "${BENCH_HOME}" ] && [ -d "${BENCH_HOME}/src" ] && [ -d "${BENCH_HOME}/run" ]; then
    log "检测到已存在 BenchmarkSQL 目录：${BENCH_HOME}，跳过解压。"
    return
  fi

  [ -f "${BENCH_ZIP}" ] || die "未找到 ${BENCH_ZIP}"

  log "使用 jar 命令解压 BenchmarkSQL 到 ${TPC_ROOT}..."
  mkdir -p "${TPC_ROOT}"
  cd "${TPC_ROOT}"

  jar xf "${BENCH_ZIP}"

  if [ ! -d "${BENCH_HOME}" ]; then
    real_dir=$(jar tf "${BENCH_ZIP}" | head -n1 | cut -d/ -f1)
    if [ -d "${TPC_ROOT}/${real_dir}" ] && [ "${TPC_ROOT}/${real_dir}" != "${BENCH_HOME}" ]; then
      mv "${TPC_ROOT}/${real_dir}" "${BENCH_HOME}"
    fi
  fi

  [ -d "${BENCH_HOME}/src" ] && [ -d "${BENCH_HOME}/run" ] || die "BenchmarkSQL 目录结构异常：${BENCH_HOME}"
  log "BenchmarkSQL 已准备完成：${BENCH_HOME}"
}

############################################
# 修改源码支持 YashanDB
############################################
patch_source() {
  log "修改 jTPCC.java / jTPCCConfig.java 支持 YashanDB..."

  local jtpcc="${BENCH_HOME}/src/client/jTPCC.java"
  local jcfg="${BENCH_HOME}/src/client/jTPCCConfig.java"

  [ -f "${jtpcc}" ] || die "未找到 ${jtpcc}"
  [ -f "${jcfg}" ]  || die "未找到 ${jcfg}"

  # jTPCC.java 中增加 yashandb 分支
  if ! grep -q 'iDB.equals("yashandb")' "${jtpcc}" 2>/dev/null; then
    sed -i 's/dbType = DB_POSTGRES;/dbType = DB_POSTGRES;\n        else if (iDB.equals("yashandb"))\n            dbType = DB_YASHANDB;/' "${jtpcc}"
    log "已在 jTPCC.java 中添加 YashanDB 分支。"
  else
    log "jTPCC.java 已包含 YashanDB 分支，跳过。"
  fi

  # jTPCCConfig.java 中扩展 DB_* 常量，增加 DB_YASHANDB = 4
  if ! grep -q 'DB_YASHANDB' "${jcfg}" 2>/dev/null; then
    sed -i 's/DB_POSTGRES = 3;/DB_POSTGRES = 3,\n\t\t\tDB_YASHANDB = 4;/' "${jcfg}"
    log "已在 jTPCCConfig.java 中添加 DB_YASHANDB 常量。"
  else
    log "jTPCCConfig.java 已包含 DB_YASHANDB，跳过。"
  fi
}

############################################
# 编译 BenchmarkSQL
############################################
build_benchmarksql() {
  log "编译 BenchmarkSQL..."
  cd "${BENCH_HOME}"
  ant
  log "BenchmarkSQL 编译完成。"
}

############################################
# 生成 props.yashandb
############################################
write_props() {
  log "生成 props.yashandb..."

  run_dir="${BENCH_HOME}/run"
  mkdir -p "${run_dir}"
  cat > "${run_dir}/props.yashandb" <<EOF
db=yashandb
driver=com.yashandb.jdbc.Driver
conn=jdbc:yasdb://${DB_HOST}:${DB_PORT}/${DB_NAME}
user=${DB_USER}
password=${DB_PASS}

warehouses=${WAREHOUSES}
loadWorkers=${LOAD_WORKERS}
terminals=${TERMINALS}
runTxnsPerTerminal=0
runMins=${RUN_MINS}
limitTxnsPerMin=0
terminalWarehouseFixed=true
newOrderWeight=45
paymentWeight=43
orderStatusWeight=4
deliveryWeight=4
stockLevelWeight=4
resultDirectory=my_result_%tY-%tm-%td_%tH%tM%tS
osCollectorScript=./misc/os_collector_linux.py
osCollectorInterval=1
EOF

  log "props.yashandb 已生成。"
}

############################################
# 覆盖 funcs.sh，拷贝 JDBC，修改 runDatabaseBuild.sh
############################################
setup_funcs_and_jdbc() {
  run_dir="${BENCH_HOME}/run"
  funcs="${run_dir}/funcs.sh"
  build_sh="${run_dir}/runDatabaseBuild.sh"
  destroy_sh="${run_dir}/runDatabaseDestroy.sh"
  run_sql_sh="${run_dir}/runSQL.sh"
  run_loader_sh="${run_dir}/runLoader.sh"
  benchmark_sh="${run_dir}/runBenchmark.sh"

  log "覆盖 funcs.sh..."

  cat > "${funcs}" <<'EOF'
# ----
# $1 is the properties file
# ----
PROPS=$1
if [ ! -f ${PROPS} ] ; then
    echo "${PROPS}: no such file" >&2
    exit 1
fi

# ----
# getProp()
#
#   Get a config value from the properties file.
# ----
function getProp()
{
    grep "^${1}=" ${PROPS} | sed -e "s/^${1}=//"
}

# ----
# setCP()
#
#   Determine the CLASSPATH based on the database system.
# ----
function setCP()
{
    case "$(getProp db)" in
        firebird)
            cp="../lib/firebird/*:../lib/*"
            ;;
        oracle)
            cp="../lib/oracle/*"
            if [ ! -z "${ORACLE_HOME}" -a -d ${ORACLE_HOME}/lib ] ; then
                cp="${cp}:${ORACLE_HOME}/lib/*"
            fi
            cp="${cp}:../lib/*"
            ;;
        postgres)
            cp="../lib/postgres/*:../lib/*"
            ;;
        yashandb)
            cp="../lib/yashandb/*:../lib/*"
            ;;
    esac
    myCP=".:${cp}:../dist/*"
    export myCP
}

# ----
# Make sure that the properties file does have db= and the value
# is a database, we support.
# ----
case "$(getProp db)" in
    firebird|oracle|postgres|yashandb)
        ;;
    "") echo "ERROR: missing db= config option in ${PROPS}" >&2
        exit 1
        ;;
    *)  echo "ERROR: unsupported database type 'db=$(getProp db)' in ${PROPS}" >&2
        exit 1
        ;;
esac
EOF

  chmod +x "${funcs}"

  log "拷贝 YashanDB JDBC 驱动到 ${JDBC_DIR_TARGET} ..."
  [ -f "${JDBC_JAR_SRC}" ] || die "未找到 ${JDBC_JAR_SRC}"
  mkdir -p "${JDBC_DIR_TARGET}"
  cp -f "${JDBC_JAR_SRC}" "${JDBC_DIR_TARGET}/"

  log "修改 runDatabaseBuild.sh 中 AFTER_LOAD..."
  [ -f "${build_sh}" ] || die "未找到 ${build_sh}"

  if grep -q 'AFTER_LOAD=' "${build_sh}"; then
    sed -i 's/^AFTER_LOAD=.*/AFTER_LOAD="indexCreates foreignKeys buildFinish"/' "${build_sh}"
  else
    echo 'AFTER_LOAD="indexCreates foreignKeys buildFinish"' >> "${build_sh}"
  fi

  chmod +x "${build_sh}"

  # 确保所有运行脚本都有执行权限，避免 Permission denied
  [ -f "${destroy_sh}" ] && chmod +x "${destroy_sh}" || true
  [ -f "${run_sql_sh}" ] && chmod +x "${run_sql_sh}" || true
  [ -f "${run_loader_sh}" ] && chmod +x "${run_loader_sh}" || true
  [ -f "${benchmark_sh}" ] && chmod +x "${benchmark_sh}" || true
}

############################################
# 执行 TPC-C：清理、装载、压测
############################################
run_tpcc() {
  log "开始执行 TPC-C 测试..."

  run_dir="${BENCH_HOME}/run"
  cd "${run_dir}"

  log "尝试清理旧数据（如首次执行失败可忽略）..."
  if ./runDatabaseDestroy.sh props.yashandb 2>&1; then
    log "旧数据清理完成。"
  else
    log "runDatabaseDestroy.sh 执行失败（可能是首次运行，无表可删），忽略。"
  fi

  log "装载 TPC-C 数据..."
  ./runDatabaseBuild.sh props.yashandb

  log "运行 BenchmarkSQL TPC-C 压测..."
  mkdir -p logs
  ts=$(date +%Y%m%d_%H%M%S)
  log_file="logs/tpcc_${ts}.log"

  ./runBenchmark.sh props.yashandb | tee "${log_file}"

  log "压测完成，日志文件：${log_file}"

  tpmc=$(grep -i 'tpmC' "${log_file}" | tail -n1 || true)
  if [ -n "${tpmc}" ]; then
    echo
    echo "================ TPC-C 摘要 ================"
    echo "${tpmc}"
    echo "==========================================="
  else
    log "未在日志中找到 tpmC 关键字，请手动检查日志。"
  fi
}

############################################
# 主流程
############################################
main() {
  log "一键 YashanDB TPC-C 安装 & 压测脚本开始执行..."
  install_jdk
  check_basic_tools
  prepare_benchmarksql
  patch_source
  build_benchmarksql
  write_props
  setup_funcs_and_jdbc
  run_tpcc
  log "脚本执行结束。"
}

main "$@"

