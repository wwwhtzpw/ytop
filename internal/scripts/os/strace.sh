#!/usr/bin/env bash
#===============================================================================
# strace.sh — 数据库工程师视角的 strace 封装
#
# 用途：从操作系统层面对数据库相关进程做 syscall 跟踪，辅助定位
#       网络阻塞、磁盘 IO、同步刷盘、锁/调度等待等问题。
#
# 默认：自动解析进程名 yasdb 的 PID；也可用 -p 指定任意进程号。
#
# 依赖：strace(1)、pgrep/pidof（其一即可）
# 注意：strace 对高频 syscall 进程开销很大，生产环境请短时、小范围使用。
#===============================================================================

# dash, or bash invoked as `sh` with posix mode (no process substitution). Re-exec with bash.
_need_bash=
if [ -z "${BASH_VERSION-}" ]; then
  _need_bash=y
elif shopt -qo posix 2>/dev/null; then
  _need_bash=y
fi
if [ -n "$_need_bash" ]; then
  _bash_for_strace_sh="$(command -v bash 2>/dev/null)" || _bash_for_strace_sh=/bin/bash
  if [ ! -x "$_bash_for_strace_sh" ]; then
    printf '%s\n' "Error: strace.sh requires Bash (not plain sh/dash, and not bash --posix)." >&2
    printf '%s\n' "Use: bash strace.sh ...   or   chmod +x ./strace.sh && ./strace.sh ..." >&2
    exit 1
  fi
  exec "$_bash_for_strace_sh" "$0" ${1+"$@"}
fi
unset _need_bash _bash_for_strace_sh

set -euo pipefail

PROGNAME="$(basename "$0")"
DEFAULT_COMM="yasdb"

# 小写（兼容 Bash 3.x，无 ${var,,}）
lc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

#-------------------------------------------------------------------------------
# 跟踪类别：strace -e trace= 列表（逗号分隔，无空格）
# 说明：不同内核/架构 syscall 名可能略有差异，若报 unknown syscall 可改小集合。
#-------------------------------------------------------------------------------

# 网络：连接与收发（TCP/UDP 常见路径）
TRACE_NETWORK="trace=connect,accept,accept4,socket,bind,listen,shutdown,setsockopt,getsockopt,getpeername,getsockname,sendto,recvfrom,sendmsg,recvmsg,send,recv"

# 文件元数据与打开关闭
TRACE_FS_META="trace=open,openat,creat,close,stat,fstat,lstat,statfs,fstatfs,access,faccessat,unlink,unlinkat,rename,renameat,chmod,fchmod,fchmodat,chown,fchown,lchown,truncate,ftruncate"

# 字节级读写与偏移（数据库数据文件、日志常见）
TRACE_IO_RW="trace=read,write,readv,writev,pread64,pwrite64,preadv,pwritev,preadv2,pwritev2,lseek,llseek"

# 刷盘与内存映射持久化相关
TRACE_SYNC="trace=fsync,fdatasync,sync_file_range,msync,sync"

# 等待与同步原语（阻塞、调度、锁）
TRACE_WAIT="trace=epoll_wait,epoll_pwait,poll,ppoll,select,pselect6,futex,nanosleep,clock_nanosleep,sched_yield"

# 内存映射（大页/ mmap IO 路径）
TRACE_MEM="trace=mmap,munmap,mremap,madvise,brk,mprotect,mlock,munlock,mlockall,munlockall"

# DBA 快速组合：最常见的“慢在哪里”线索
TRACE_QUICK="trace=connect,accept,accept4,sendto,recvfrom,sendmsg,recvmsg,send,recv,read,write,pread64,pwrite64,open,openat,close,fsync,fdatasync,epoll_wait,epoll_pwait,poll,futex,nanosleep,mmap,munmap"

# 仅连接阶段（排查握手/超时）
TRACE_CONNECT="trace=connect,socket,setsockopt,getsockopt"

# 仅磁盘读写与刷盘（排查 IO 与 fsync）
TRACE_DISK="trace=read,write,pread64,pwrite64,open,openat,close,fsync,fdatasync,sync_file_range,msync,lseek"

usage() {
  cat <<EOF
Usage: $PROGNAME [options] [-- extra strace arguments]

Requires Bash (process substitution, arrays). If you run \`sh $PROGNAME\`, the script
re-execs with \`bash\` when the shell is not full Bash (e.g. dash, or bash in POSIX mode).

Options:
  -h              Show this help
  -l              List trace categories and descriptions
  -p PID          Target PID (if omitted, resolve by process name: ${DEFAULT_COMM})
                  If several match, you are prompted on a TTY; otherwise use -p
  -n NAME         Process name used to resolve PID (default: ${DEFAULT_COMM})
  -c CATEGORY     Trace category (default: quick)
  -o FILE         strace -o output prefix; with -ff, writes FILE.<pid> files
  -f              Follow forks (strace -f)
  -F              Same as strace -ff (one file per pid; use with -o recommended)
  -C              Count mode: syscall summary on exit (strace -c)
  -y              Print paths next to fds in syscall lines (strace -y); e.g. pread64(3</path>,...)
                  Auto-on for categories: disk, io, full_io, sync, quick, io_net (unless STRACE_SH_NO_AUTO_Y=1)
  -s SIZE         Optional strace -s (string print limit; omit for strace default)
  -d              Dry-run: print the strace command only, do not execute
                  Note: put -d BEFORE -- ; after -- it is passed to strace as debug -d

Categories (-c):
  quick       Default mix: network + read/write + open/close + fsync + common waits + mmap
  network     Sockets and send/recv
  fs          open/close/stat-style metadata
  io          Byte reads/writes and lseek
  sync        fsync / fdatasync / msync / sync
  wait        epoll / poll / select / futex / sleep
  mem         mmap / brk / mprotect, etc.
  disk        Storage-focused subset (rw + open + fsync), no network
  connect     connect/socket only (slow connect / timeouts)
  io_net      Disk + network without wait syscalls
  full_io     io + fs metadata + sync (heavier disk-side set)
  custom      Pass your own -e trace=... after --

Default strace flags (non -C):
  -ttt -T      Timestamps + per-syscall time

Yasdb default:
  If /proc/<pid>/comm is yasdb and you did not pass -f/-F, the script adds -f automatically
  (fork/exec helpers). Opt out: STRACE_SH_NO_AUTO_FORK=1

Fd paths in output (pread64/write/...):
  strace -y is added automatically for disk/io/full_io/sync/quick/io_net unless STRACE_SH_NO_AUTO_Y=1.
  Or pass -y explicitly any time.

Extra strace args:
  Append at the end, or after --, e.g.:
  $PROGNAME -p 1 -c custom -- -e trace=read,write

Examples:
  # Default: resolve ${DEFAULT_COMM}, category quick
  sudo $PROGNAME

  # Fixed PID, network only
  sudo $PROGNAME -p 6326 -c network

  # Different comm name, log to file, follow children
  sudo $PROGNAME -n yashandb -c quick -o /tmp/yashandb.strace -f

  # Count mode (Ctrl+C to stop and print summary)
  sudo $PROGNAME -p 6326 -C -c quick

  # Dry-run (keep -d before --)
  $PROGNAME -p 1 -c network -d

  # custom: this script's flags first, strace flags after --
  $PROGNAME -p 1 -d -c custom -- -e trace=read,write
EOF
}

list_categories() {
  cat <<EOF
=== Trace categories (DBA / OS troubleshooting) ===

  quick       First choice: network + datafile rw + open/close + fsync + common blocks + mmap
  network     Connect/send/recv latency, unreachable peer (use -T per call)
  fs          Many small files, bad paths, permissions, churning open/close
  io          Large read/write, pwrite ordering and latency
  sync        Heavy flush: fsync/fdatasync time, checkpoint-like hints
  wait        Low CPU but "stuck": locks, epoll, sleep
  mem         mmap growth / address space
  disk        Storage side: rw + open + fsync, no network syscalls
  connect     Connection establishment only
  io_net      Disk + network without wait syscalls (less noise)
  full_io     Broader disk side: io + metadata + sync
  custom      Add -e 'trace=...' etc. after --

=== Rough mapping to common DB symptoms (heuristic) ===

  Slow connect / timeout     -> connect or network
  Slow queries + disk busy   -> disk / sync / quick
  Many sessions, low tput    -> wait + io (long futex/epoll_wait?)
  Replication/backup net     -> network + io if needed

EOF
}

# Print matching PIDs, one per line, sorted numerically (unique).
list_pids_by_name() {
  local name="$1"
  local pids=()

  if command -v pidof >/dev/null 2>&1; then
    # shellcheck disable=SC2207
    pids=( $(pidof "$name" 2>/dev/null || true) )
  fi

  if [[ ${#pids[@]} -eq 0 ]] && command -v pgrep >/dev/null 2>&1; then
    # 精确匹配进程名（comm）
    while IFS= read -r line; do
      [[ -n "$line" ]] && pids+=("$line")
    done < <(pgrep -x "$name" 2>/dev/null || true)
  fi

  if [[ ${#pids[@]} -eq 0 ]] && command -v pgrep >/dev/null 2>&1; then
    # 宽松：命令行包含 name（注意可能误匹配，仅作兜底）
    while IFS= read -r line; do
      [[ -n "$line" ]] && pids+=("$line")
    done < <(pgrep -f "$name" 2>/dev/null | head -20 || true)
  fi

  # 去重
  if [[ ${#pids[@]} -gt 0 ]]; then
    printf '%s\n' "${pids[@]}" | sort -u -n
  fi
}

# Print a one-line cmdline for display (paths like yasdb_home/... and -D ... vary).
format_pid_cmdline() {
  local p="$1"
  local line max=160
  if [[ -r "/proc/$p/cmdline" ]]; then
    line="$(tr '\0' ' ' < "/proc/$p/cmdline")"
  else
    line="(cmdline unreadable)"
  fi
  if [[ ${#line} -gt $max ]]; then
    line="${line:0:$max}..."
  fi
  printf '%s\n' "$line"
}

# Interactive menu when multiple processes match. Prints chosen PID on stdout.
prompt_pick_pid() {
  local comm="$1"
  shift
  local pids=("$@")
  local i pid line choice

  echo "Multiple \"${comm}\" processes found. Select one:" >&2
  i=1
  for pid in "${pids[@]}"; do
    line="$(format_pid_cmdline "$pid")"
    printf '  [%u] pid=%s  %s\n' "$i" "$pid" "$line" >&2
    i=$((i + 1))
  done

  while true; do
    printf 'Enter choice [1-%u] or a PID listed above: ' "${#pids[@]}" >&2
    if ! read -r choice; then
      echo "Error: EOF on stdin; aborted." >&2
      exit 1
    fi
    if [[ -z "$choice" ]]; then
      echo "Empty input; try again." >&2
      continue
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      for pid in "${pids[@]}"; do
        if [[ "$choice" == "$pid" ]]; then
          printf '%s\n' "$pid"
          return 0
        fi
      done
      if [[ "$choice" -ge 1 && "$choice" -le ${#pids[@]} ]]; then
        printf '%s\n' "${pids[$((choice - 1))]}"
        return 0
      fi
    fi
    echo "Invalid choice. Enter a menu index (1-${#pids[@]}) or one of the PIDs." >&2
  done
}

pick_trace_expr() {
  local cat
  cat="$(lc "$1")"
  case "$cat" in
    quick)     printf '%s %s\n' "-e" "$TRACE_QUICK" ;;
    network)   printf '%s %s\n' "-e" "$TRACE_NETWORK" ;;
    fs)        printf '%s %s\n' "-e" "$TRACE_FS_META" ;;
    io)        printf '%s %s\n' "-e" "$TRACE_IO_RW" ;;
    sync)      printf '%s %s\n' "-e" "$TRACE_SYNC" ;;
    wait)      printf '%s %s\n' "-e" "$TRACE_WAIT" ;;
    mem)       printf '%s %s\n' "-e" "$TRACE_MEM" ;;
    disk)      printf '%s %s\n' "-e" "$TRACE_DISK" ;;
    connect)   printf '%s %s\n' "-e" "$TRACE_CONNECT" ;;
    io_net)    printf '%s %s\n' "-e" "trace=connect,accept,accept4,sendto,recvfrom,sendmsg,recvmsg,send,recv,read,write,pread64,pwrite64,open,openat,close" ;;
    custom)    printf '\n' ;;
    *)
      echo "Unknown category: $1" >&2
      echo "Run with -l for the category list." >&2
      exit 2
      ;;
  esac
}

# full_io: 合并 trace= 三段
build_full_io() {
  printf '%s %s\n' "-e" "trace=read,write,readv,writev,pread64,pwrite64,preadv,pwritev,preadv2,pwritev2,lseek,llseek,open,openat,creat,close,stat,fstat,lstat,statfs,fstatfs,access,faccessat,unlink,unlinkat,rename,renameat,chmod,fchmod,fchmodat,chown,fchown,lchown,truncate,ftruncate,fsync,fdatasync,sync_file_range,msync,sync"
}

main() {
  local pid=""
  local comm_name="$DEFAULT_COMM"
  local category="quick"
  local outfile=""
  local follow_fork=0
  local follow_ff=0
  local count_mode=0
  local strace_y=0
  local strace_s=""
  local dry_run=0
  local help=0
  local list=0

  local OPTIND=1 opt
  while getopts "hlp:n:c:o:fFCys:d" opt; do
    case "$opt" in
      h) help=1 ;;
      l) list=1 ;;
      p) pid="$OPTARG" ;;
      n) comm_name="$OPTARG" ;;
      c) category="$OPTARG" ;;
      o) outfile="$OPTARG" ;;
      f) follow_fork=1 ;;
      F) follow_ff=1 ;;
      C) count_mode=1 ;;
      y) strace_y=1 ;;
      s) strace_s="$OPTARG" ;;
      d) dry_run=1 ;;
      *) usage; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))
  if [[ "${1-}" == "--" ]]; then
    shift
  fi

  if [[ "$help" -eq 1 ]]; then
    usage
    exit 0
  fi
  if [[ "$list" -eq 1 ]]; then
    list_categories
    exit 0
  fi

  if ! command -v strace >/dev/null 2>&1; then
    echo "Error: strace not found. Install it (e.g. yum install -y strace or apt install -y strace)." >&2
    exit 1
  fi

  if [[ -z "$pid" ]]; then
    local pid_list=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && pid_list+=("$line")
    done < <(list_pids_by_name "$comm_name")

    if [[ ${#pid_list[@]} -eq 0 ]]; then
      echo "Error: no PID found for process name '${comm_name}'. Use -p or change -n." >&2
      exit 1
    elif [[ ${#pid_list[@]} -eq 1 ]]; then
      pid="${pid_list[0]}"
    else
      # Several instances (e.g. different yasdb_home / -D data paths): pick one.
      if [[ "$dry_run" -eq 1 ]] || [[ ! -t 0 ]]; then
        echo "Error: multiple \"${comm_name}\" processes match; disambiguate with -p <PID>." >&2
        echo "Matches:" >&2
        local idx=1
        for p in "${pid_list[@]}"; do
          printf '  [%u] pid=%s  %s\n' "$idx" "$p" "$(format_pid_cmdline "$p")" >&2
          idx=$((idx + 1))
        done
        if [[ "$dry_run" -eq 1 ]]; then
          echo "Note: dry-run (-d) does not prompt; pass -p explicitly when several instances exist." >&2
        else
          echo "Note: stdin is not a TTY; re-run from an interactive shell or use -p." >&2
        fi
        exit 1
      fi
      pid="$(prompt_pick_pid "$comm_name" "${pid_list[@]}")"
    fi
  fi

  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "Error: invalid PID: $pid" >&2
    exit 1
  fi

  if [[ ! -r "/proc/$pid/cmdline" ]]; then
    echo "Error: cannot read /proc/$pid (process missing or no permission). Tracing other users' processes usually requires root." >&2
    exit 1
  fi

  local cat_lc
  cat_lc="$(lc "$category")"

  # On 10.10.10.125-style hosts: yasdb is multi-threaded; it may also fork short-lived helpers.
  # strace -p already traces threads in the same group, but -f is still recommended for forked children.
  if [[ -z "${STRACE_SH_NO_AUTO_FORK-}" ]] && [[ "$follow_fork" -eq 0 ]] && [[ "$follow_ff" -eq 0 ]]; then
    local proc_comm=""
    if [[ -r "/proc/$pid/comm" ]]; then
      proc_comm="$(tr '\0' '\n' < "/proc/$pid/comm" | head -n1)"
    fi
    proc_comm="$(lc "$proc_comm")"
    if [[ "$proc_comm" == "yasdb" ]]; then
      follow_fork=1
      echo ">>> auto-enabled -f for yasdb (follow forks). Disable: STRACE_SH_NO_AUTO_FORK=1 $PROGNAME ..." >&2
    fi
  fi

  # strace -y: show path next to fd (e.g. pread64(36</dev/yfs/sys1>, buf, ...)).
  if [[ -z "${STRACE_SH_NO_AUTO_Y-}" ]] && [[ "$strace_y" -eq 0 ]]; then
    case "$cat_lc" in
      disk|io|full_io|sync|quick|io_net)
        strace_y=1
        echo ">>> auto-enabled -y (fd paths in syscall lines). Disable: STRACE_SH_NO_AUTO_Y=1 $PROGNAME ..." >&2
        ;;
    esac
  fi

  local trace_args=()
  if [[ "$cat_lc" == "full_io" ]]; then
    read -r -a trace_args < <(build_full_io)
  elif [[ "$cat_lc" == "custom" ]]; then
    trace_args=()
  else
    read -r -a trace_args < <(pick_trace_expr "$category")
  fi

  local cmd=(strace)

  if [[ "$count_mode" -eq 1 ]]; then
    cmd+=(-c)
  else
    cmd+=(-ttt -T)
  fi

  if [[ "$follow_fork" -eq 1 ]]; then
    cmd+=(-f)
  fi
  if [[ "$follow_ff" -eq 1 ]]; then
    cmd+=(-ff)
  fi

  if [[ -n "$outfile" ]]; then
    cmd+=(-o "$outfile")
  fi

  if [[ "$strace_y" -eq 1 ]]; then
    cmd+=(-y)
  fi
  if [[ -n "$strace_s" ]]; then
    cmd+=(-s "$strace_s")
  fi

  if [[ ${#trace_args[@]} -gt 0 ]]; then
    cmd+=("${trace_args[@]}")
  fi

  cmd+=(-p "$pid")
  cmd+=("$@")

  echo ">>> target pid=$pid category=$category resolve_name=${comm_name}" >&2
  if [[ -r "/proc/$pid/cmdline" ]]; then
    echo ">>> cmdline: $(tr '\0' ' ' < "/proc/$pid/cmdline")" >&2
  fi
  echo ">>> exec: ${cmd[*]}" >&2

  if [[ "$dry_run" -eq 1 ]]; then
    printf '%q ' "${cmd[@]}"
    echo
    exit 0
  fi

  exec "${cmd[@]}"
}

main "$@"
