#!/usr/bin/env bash
set -euo pipefail

# trace_tid_io.sh
# Trace syscall latency for a process (default: yasdb) and optionally a specific thread (TID):
# pread64/pwrite64/read/write/preadv/pwritev/readv/writev
#
# Measurement: syscall enter -> syscall exit latency (microseconds).
# Note: this is syscall latency, NOT block-layer physical IO completion latency (async IO/background flush can differ).
#
# Examples:
#   1) Auto-detect yasdb PID (all threads, no min threshold, run until Ctrl+C)
#      ./trace_tid_io.sh
#   2) Trace a specific PID
#      ./trace_tid_io.sh -p 457090
#   3) Trace a specific thread TID, and only print calls >= 1ms
#      ./trace_tid_io.sh -p 457090 -t 457098 -m 1000
#   4) Filter by thread name (COMM shown by ps -T), e.g. DBWR/LOGW/CKPT/WORKER
#      ./trace_tid_io.sh -p 457090 -n DBWR -m 1000
#   5) Run for 30 seconds
#      ./trace_tid_io.sh -d 30
#

COMM_DEFAULT="yasdb"
PID=""
COMM="$COMM_DEFAULT"
COMM_EXPLICIT="0"
TID="0"
TNAME=""
TID_LIST=""
MIN_US="0"
DURATION="0"
BPFTRACE_BUF="none"
OPS_MODE="io"           # all | io
IGNORE_EAGAIN="0"       # 0 | 1 (仅对 read/write 生效)
SHOW_FD_PATH="0"        # 0|1 Append FD target (via /proc/<pid>/fd/<fd>)
FD_PATH_INTERVAL="2"    # seconds: refresh interval for FD->PATH map (lower = more overhead)
QUIET="1"               # 0|1 Quiet mode: hide script INFO and bpftrace Attaching/Tracing banners (default ON)

usage() {
  cat <<EOF >&2
Usage: ${0##*/} [options]

options:
  -p PID        Target process PID (overrides -c)
  -c COMM       Process name/keyword (default: ${COMM_DEFAULT}) used to auto-detect PID (oldest match)
  -t TID        Target thread ID (TID). 0 means all threads (default: 0)
  -n TNAME      Filter by thread name (COMM shown by ps -T), e.g. DBWR/LOGW/CKPT/WORKER
  -m MIN_US     Min latency threshold in microseconds (default: 0)
  -d SECONDS    Duration in seconds, 0 means run until Ctrl+C (default: 0)
  -B MODE       bpftrace output buffering: none/full (default: none)
  -O MODE       Syscall set: all/io (default: io; io = pread/pwrite/preadv/pwritev only)
  -G 0|1        Ignore read/write output when ret == -11 (EAGAIN) (default: 0)
  -P 0|1        Append FD target (default: 0; via /proc/<pid>/fd/<fd>)
  -I SECONDS    FD->PATH map refresh interval in seconds (default: 2; only with -P 1)
  -q            Quiet mode: hide INFO and bpftrace banners (default ON)
  -h            Help

Examples:
  ${0##*/}                      # Auto-detect yasdb
  ${0##*/} -p 457090 -t 457098  # Specific thread
  ${0##*/} -p 457090 -n DBWR    # Filter by thread name
  ${0##*/} -m 1000 -d 30        # Only print calls >= 1ms, run for 30s
EOF
}

while getopts ":p:c:t:n:m:d:B:O:G:P:I:qh" opt; do
  case "$opt" in
    p) PID="$OPTARG" ;;
    c) COMM="$OPTARG"; COMM_EXPLICIT="1" ;;
    t) TID="$OPTARG" ;;
    n) TNAME="$OPTARG" ;;
    m) MIN_US="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    B) BPFTRACE_BUF="$OPTARG" ;;
    O) OPS_MODE="$OPTARG" ;;
    G) IGNORE_EAGAIN="$OPTARG" ;;
    P) SHOW_FD_PATH="$OPTARG" ;;
    I) FD_PATH_INTERVAL="$OPTARG" ;;
    q) QUIET="1" ;;
    h) usage; exit 0 ;;
    :) echo "ERROR: -$OPTARG requires a value" >&2; usage; exit 2 ;;
    \?) echo "ERROR: unknown option -$OPTARG" >&2; usage; exit 2 ;;
  esac
done

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
if [[ -n "$PID" ]] && ! is_uint "$PID"; then echo "ERROR: PID must be a number" >&2; exit 2; fi
if ! is_uint "$TID"; then echo "ERROR: TID must be a number" >&2; exit 2; fi
if ! is_uint "$MIN_US"; then echo "ERROR: MIN_US must be a number" >&2; exit 2; fi
if ! is_uint "$DURATION"; then echo "ERROR: DURATION must be a number" >&2; exit 2; fi
if [[ "$BPFTRACE_BUF" != "none" && "$BPFTRACE_BUF" != "full" ]]; then
  echo "ERROR: -B only supports: none | full" >&2
  exit 2
fi
if [[ "$OPS_MODE" != "all" && "$OPS_MODE" != "io" ]]; then
  echo "ERROR: -O only supports: all | io" >&2
  exit 2
fi
if [[ "$IGNORE_EAGAIN" != "0" && "$IGNORE_EAGAIN" != "1" ]]; then
  echo "ERROR: -G only supports: 0 | 1" >&2
  exit 2
fi
if [[ "$SHOW_FD_PATH" != "0" && "$SHOW_FD_PATH" != "1" ]]; then
  echo "ERROR: -P only supports: 0 | 1" >&2
  exit 2
fi
if [[ "$QUIET" != "0" && "$QUIET" != "1" ]]; then
  echo "ERROR: invalid -q value" >&2
  exit 2
fi
if ! is_uint "$FD_PATH_INTERVAL" || [[ "$FD_PATH_INTERVAL" -le 0 ]]; then
  echo "ERROR: -I must be a positive integer (seconds)" >&2
  exit 2
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 1; }; }
need_cmd bpftrace
need_cmd ps
need_cmd awk
need_cmd sed

if [[ -z "$PID" ]]; then
  # Pick the oldest matching process:
  # - When -c is explicitly provided: exact match only (avoid matching bash/ssh command line)
  # - Default yasdb: exact match first, fallback to -f
  PID="$(pgrep -o -x "$COMM" 2>/dev/null || true)"
  if [[ -z "$PID" && "$COMM_EXPLICIT" == "0" ]]; then
    PID="$(pgrep -o -f "$COMM" 2>/dev/null || true)"
  fi
  if [[ -z "$PID" ]]; then
    echo "ERROR: process not found (-c $COMM)" >&2
    exit 1
  fi
fi

# Validate PID exists
if ! ps -p "$PID" >/dev/null 2>&1; then
  echo "ERROR: PID $PID does not exist" >&2
  exit 1
fi

if [[ -n "$TNAME" ]]; then
  # Resolve thread(s) by name from ps -T
  matches="$(ps -T -p "$PID" -o tid=,comm= | awk -v n="$TNAME" '$2==n{print $1}')"
  count="$(echo "$matches" | awk 'NF{c++} END{print c+0}')"
  if [[ "$count" -eq 0 ]]; then
    echo "ERROR: thread name not found in PID=$PID (comm)=$TNAME" >&2
    echo "Thread list (first 50 lines):" >&2
    ps -T -p "$PID" -o tid,comm | head -50 >&2
    exit 1
  fi
  # If -t is not explicitly set, build a TID list filter for all matches (e.g. multiple DBWR/WORKER)
  if [[ "$TID" == "0" ]]; then
    TID_LIST="$(echo "$matches" | awk 'NF{print $1}' | paste -sd, -)"
    # If only one match, also set -t fast path
    if [[ "$count" -eq 1 ]]; then
      TID="$(echo "$matches" | awk 'NF{print $1; exit}')"
    fi
  fi
fi

BT="/tmp/trace_io_${PID}_${TID}.bt"

TIDLIST_PRED=""
if [[ -n "$TID_LIST" && "$TID" == "0" ]]; then
  # 构造 (tid==a || tid==b || ...)
  TIDLIST_PRED=" && ("
  IFS=',' read -r -a _tids <<<"$TID_LIST"
  for i in "${!_tids[@]}"; do
    if [[ "$i" -gt 0 ]]; then TIDLIST_PRED+=" || "; fi
    TIDLIST_PRED+="tid==${_tids[$i]}"
  done
  TIDLIST_PRED+=")"
fi

cat >"$BT" <<'BT'
BEGIN {
  if (__SHOW_BANNER__) {
    printf("Tracing IO syscalls: pid=%d tid=%d min_us=%d (tid=0 means all threads) ...\n", __PID__, __TID__, __MIN_US__);
  }
  printf("%-15s %-16s %-8s %-8s %-9s %-4s %-10s %-10s %-10s %-12s\n",
         "TIME","COMM","PID","TID","OP","FD","REQ","RET","LAT(us)","OFF");
}

// syscall_id: 0 pread64, 1 pwrite64, 2 read, 3 write, 4 preadv, 5 pwritev, 6 readv, 7 writev
// __TRACE_RW__ : 1/0 是否追踪 read/write/readv/writev
// __IGNORE_EAGAIN__ : 1/0 是否忽略 read/write ret=-11 的输出

tracepoint:syscalls:sys_enter_pread64  / pid==__PID__ && (__TID__==0 || tid==__TID__)__TIDLIST_PRED__ / { @ts[tid,0]=nsecs; @fd[tid,0]=args->fd; @req[tid,0]=args->count; @off[tid,0]=args->pos; }
tracepoint:syscalls:sys_exit_pread64   / @ts[tid,0] / { $us=(nsecs-@ts[tid,0])/1000; if($us>=__MIN_US__){printf("%s.%06d %-16s %-8d %-8d %-9s %-4d %-10d %-10d %-10d %-12lld\n", strftime("%H:%M:%S", nsecs), (nsecs % 1000000000) / 1000, comm,pid,tid,"pread64",@fd[tid,0],@req[tid,0],args->ret,$us,@off[tid,0]);} delete(@ts[tid,0]); delete(@fd[tid,0]); delete(@req[tid,0]); delete(@off[tid,0]); }

tracepoint:syscalls:sys_enter_pwrite64 / pid==__PID__ && (__TID__==0 || tid==__TID__)__TIDLIST_PRED__ / { @ts[tid,1]=nsecs; @fd[tid,1]=args->fd; @req[tid,1]=args->count; @off[tid,1]=args->pos; }
tracepoint:syscalls:sys_exit_pwrite64  / @ts[tid,1] / { $us=(nsecs-@ts[tid,1])/1000; if($us>=__MIN_US__){printf("%s.%06d %-16s %-8d %-8d %-9s %-4d %-10d %-10d %-10d %-12lld\n", strftime("%H:%M:%S", nsecs), (nsecs % 1000000000) / 1000, comm,pid,tid,"pwrite64",@fd[tid,1],@req[tid,1],args->ret,$us,@off[tid,1]);} delete(@ts[tid,1]); delete(@fd[tid,1]); delete(@req[tid,1]); delete(@off[tid,1]); }

tracepoint:syscalls:sys_enter_read    / __TRACE_RW__ && pid==__PID__ && (__TID__==0 || tid==__TID__)__TIDLIST_PRED__ / { @ts[tid,2]=nsecs; @fd[tid,2]=args->fd; @req[tid,2]=args->count; }
tracepoint:syscalls:sys_exit_read     / @ts[tid,2] / { $us=(nsecs-@ts[tid,2])/1000; if(!(__IGNORE_EAGAIN__ && args->ret==-11) && $us>=__MIN_US__){printf("%s.%06d %-16s %-8d %-8d %-9s %-4d %-10d %-10d %-10d %-12s\n", strftime("%H:%M:%S", nsecs), (nsecs % 1000000000) / 1000, comm,pid,tid,"read",@fd[tid,2],@req[tid,2],args->ret,$us,"-");} delete(@ts[tid,2]); delete(@fd[tid,2]); delete(@req[tid,2]); }

tracepoint:syscalls:sys_enter_write   / __TRACE_RW__ && pid==__PID__ && (__TID__==0 || tid==__TID__)__TIDLIST_PRED__ / { @ts[tid,3]=nsecs; @fd[tid,3]=args->fd; @req[tid,3]=args->count; }
tracepoint:syscalls:sys_exit_write    / @ts[tid,3] / { $us=(nsecs-@ts[tid,3])/1000; if($us>=__MIN_US__){printf("%s.%06d %-16s %-8d %-8d %-9s %-4d %-10d %-10d %-10d %-12s\n", strftime("%H:%M:%S", nsecs), (nsecs % 1000000000) / 1000, comm,pid,tid,"write",@fd[tid,3],@req[tid,3],args->ret,$us,"-");} delete(@ts[tid,3]); delete(@fd[tid,3]); delete(@req[tid,3]); }

tracepoint:syscalls:sys_enter_preadv  / pid==__PID__ && (__TID__==0 || tid==__TID__)__TIDLIST_PRED__ / { @ts[tid,4]=nsecs; @fd[tid,4]=args->fd; }
tracepoint:syscalls:sys_exit_preadv   / @ts[tid,4] / { $us=(nsecs-@ts[tid,4])/1000; if($us>=__MIN_US__){printf("%s.%06d %-16s %-8d %-8d %-9s %-4d %-10s %-10d %-10d %-12s\n", strftime("%H:%M:%S", nsecs), (nsecs % 1000000000) / 1000, comm,pid,tid,"preadv",@fd[tid,4],"-",args->ret,$us,"-");} delete(@ts[tid,4]); delete(@fd[tid,4]); }

tracepoint:syscalls:sys_enter_pwritev / pid==__PID__ && (__TID__==0 || tid==__TID__)__TIDLIST_PRED__ / { @ts[tid,5]=nsecs; @fd[tid,5]=args->fd; }
tracepoint:syscalls:sys_exit_pwritev  / @ts[tid,5] / { $us=(nsecs-@ts[tid,5])/1000; if($us>=__MIN_US__){printf("%s.%06d %-16s %-8d %-8d %-9s %-4d %-10s %-10d %-10d %-12s\n", strftime("%H:%M:%S", nsecs), (nsecs % 1000000000) / 1000, comm,pid,tid,"pwritev",@fd[tid,5],"-",args->ret,$us,"-");} delete(@ts[tid,5]); delete(@fd[tid,5]); }

tracepoint:syscalls:sys_enter_readv   / __TRACE_RW__ && pid==__PID__ && (__TID__==0 || tid==__TID__)__TIDLIST_PRED__ / { @ts[tid,6]=nsecs; @fd[tid,6]=args->fd; }
tracepoint:syscalls:sys_exit_readv    / @ts[tid,6] / { $us=(nsecs-@ts[tid,6])/1000; if($us>=__MIN_US__){printf("%s.%06d %-16s %-8d %-8d %-9s %-4d %-10s %-10d %-10d %-12s\n", strftime("%H:%M:%S", nsecs), (nsecs % 1000000000) / 1000, comm,pid,tid,"readv",@fd[tid,6],"-",args->ret,$us,"-");} delete(@ts[tid,6]); delete(@fd[tid,6]); }

tracepoint:syscalls:sys_enter_writev  / __TRACE_RW__ && pid==__PID__ && (__TID__==0 || tid==__TID__)__TIDLIST_PRED__ / { @ts[tid,7]=nsecs; @fd[tid,7]=args->fd; }
tracepoint:syscalls:sys_exit_writev   / @ts[tid,7] / { $us=(nsecs-@ts[tid,7])/1000; if($us>=__MIN_US__){printf("%s.%06d %-16s %-8d %-8d %-9s %-4d %-10s %-10d %-10d %-12s\n", strftime("%H:%M:%S", nsecs), (nsecs % 1000000000) / 1000, comm,pid,tid,"writev",@fd[tid,7],"-",args->ret,$us,"-");} delete(@ts[tid,7]); delete(@fd[tid,7]); }

END {
  // 避免 timeout/中断时打印大量残留 map
  clear(@ts); clear(@fd); clear(@req); clear(@off);
}
BT

# 用 sed 替换占位符，避免 shell 展开 bpftrace 的 $变量
escape_sed_repl() { sed -e 's/[\\/&]/\\&/g'; }
TIDLIST_PRED_ESCAPED="$(printf '%s' "$TIDLIST_PRED" | escape_sed_repl)"
SHOW_BANNER="${QUIET}"
if [[ "$QUIET" == "1" ]]; then SHOW_BANNER="0"; else SHOW_BANNER="1"; fi

sed -i \
  -e "s/__PID__/${PID}/g" \
  -e "s/__TID__/${TID}/g" \
  -e "s/__MIN_US__/${MIN_US}/g" \
  -e "s/__SHOW_BANNER__/${SHOW_BANNER}/g" \
  -e "s/__TRACE_RW__/$( [[ \"$OPS_MODE\" == \"io\" ]] && echo 0 || echo 1 )/g" \
  -e "s/__IGNORE_EAGAIN__/${IGNORE_EAGAIN}/g" \
  -e "s/__TIDLIST_PRED__/${TIDLIST_PRED_ESCAPED}/g" \
  "$BT"

target_comm="$(ps -p "$PID" -o comm= 2>/dev/null | awk '{print $1}' || true)"
extra=""
if [[ -n "$TNAME" ]]; then extra=" tname=$TNAME"; fi
if [[ "$QUIET" != "1" ]]; then
  echo "[INFO] target: pid=$PID comm=${target_comm:-unknown} tid=$TID min_us=$MIN_US duration=$DURATION${extra}"
  echo "[INFO] bpftrace script: $BT"
  echo "[INFO] bpftrace buffer: $BPFTRACE_BUF"
  echo "[INFO] ops mode: $OPS_MODE  ignore_eagain: $IGNORE_EAGAIN"
  echo "[INFO] fd->path: $SHOW_FD_PATH (interval=${FD_PATH_INTERVAL}s)"
  echo "[INFO] running... (Ctrl+C stop)"
fi

fdmap_dir=""
fdmap_file=""
fdmap_pid=""
cleanup() {
  if [[ -n "${fdmap_pid:-}" ]]; then
    kill "$fdmap_pid" 2>/dev/null || true
    wait "$fdmap_pid" 2>/dev/null || true
  fi
  if [[ -n "${fdmap_dir:-}" ]]; then
    rm -rf "$fdmap_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_fd_mapper() {
  fdmap_dir="/tmp/trace_tid_io_fdmap_${PID}"
  fdmap_file="${fdmap_dir}/map.tsv"
  mkdir -p "$fdmap_dir"
  (
    while true; do
      tmp="${fdmap_file}.new"
      : >"$tmp"
      if [[ -d "/proc/${PID}/fd" ]]; then
        for f in /proc/${PID}/fd/*; do
          [[ -e "$f" ]] || continue
          fd="${f##*/}"
          target="$(readlink "$f" 2>/dev/null || echo "?")"
          printf "%s\t%s\n" "$fd" "$target" >>"$tmp"
        done
      fi
      mv -f "$tmp" "$fdmap_file" 2>/dev/null || true
      sleep "$FD_PATH_INTERVAL"
    done
  ) &
  fdmap_pid="$!"
}

run_bpftrace() {
  quiet_flag=""
  if [[ "$QUIET" == "1" ]]; then quiet_flag="-q"; fi
  if [[ "$DURATION" -gt 0 ]]; then
    timeout "$DURATION" sudo bpftrace $quiet_flag -B "$BPFTRACE_BUF" "$BT"
  else
    sudo bpftrace $quiet_flag -B "$BPFTRACE_BUF" "$BT"
  fi
}

if [[ "$SHOW_FD_PATH" == "1" ]]; then
  start_fd_mapper
  # Append PATH column in user space (readlink /proc/<pid>/fd/<fd>).
  # Note: FD reuse / rapid close can cause rare transient mismatches.
  {
    run_bpftrace
  } | awk -v mapfile="$fdmap_file" '
    BEGIN { OFS="\t"; last_load=0; load_map(); }
    function load_map(    line, a) {
      fd2path_size=0
      while ((getline line < mapfile) > 0) {
        split(line, a, "\t")
        fd2path[a[1]] = a[2]
        fd2path_size++
      }
      close(mapfile)
      last_load = systime()
    }
    function get_path(fd,    p) {
      if ((systime() - last_load) >= 1) load_map()
      p = fd2path[fd]
      if (p == "") p = "?"
      return p
    }
    # info/attach/header 行原样输出；表头行追加 PATH
    /^\[INFO\]/ { print $0; next }
    /^Attaching/ { print $0; next }
    /^Tracing IO/ { print $0; next }
    /^TIME[[:space:]]+COMM/ { print $0, "PATH"; next }
    NF < 10 { print $0; next }
    {
      # 默认输出列：TIME COMM PID TID OP FD REQ RET LAT(us) OFF
      fd = $6
      print $0, get_path(fd)
    }
  '
else
  run_bpftrace
fi


