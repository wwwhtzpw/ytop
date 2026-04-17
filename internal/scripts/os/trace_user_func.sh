#!/usr/bin/env bash
set -euo pipefail

# trace_yashandb.sh
#
# Event-based user-space function tracing using bpftrace uprobes.
# Designed to resemble: strace -ff -ttt -T
# - -ttt: timestamp (customizable; default in this script: HH:MM:SS.microseconds)
# - -T:   duration per call (<seconds.microseconds>)
# - -ff:  split output by TID into separate files (implemented via awk)
#
# This script focuses on Scheme A (event tracing). Scheme B (sampling) is removed
# because it can be done via perf.
#
# Notes:
# - Tracing huge function sets is expensive. Always narrow with -F.
# - Function arguments are not decoded (unlike strace). We print func name + retval.
# - Recursive/re-entrant calls are handled via a per-(tid,func) depth stack.

COMM_DEFAULT="yasdb"

PID=""
TID="0"                # 0 means all threads
COMM="$COMM_DEFAULT"
BINARY_PATH=""         # default: /proc/<pid>/exe
LIBS=""                # comma-separated extra .so absolute paths
FUNC_GLOB=""           # required, bpftrace glob
MIN_US="0"
DURATION="0"           # 0 = until Ctrl+C
OUT_PREFIX=""          # like strace -o PREFIX
SPLIT_FF="1"           # emulate strace -ff by splitting per TID (best with -o)
QUIET="1"              # default quiet
BPFTRACE_BUF="none"    # none|full
INCLUDE_BIN="1"        # 1 = include main binary in targets; 0 = only trace libs (-l)
TRACE_MODE="return"    # return|entry|both (dtrace-like)

usage() {
  cat <<EOF >&2
Usage: ${0##*/} [options]

Required:
  -F GLOB         Function glob to trace (recommended). Examples: "anr*", "btree*", "pthread_mutex_lock"

Options:
  -p PID          Target process PID (default: auto-detect by -c)
  -t TID          Target thread ID (0 means all threads; default: 0)
  -c COMM         Process name/keyword used to auto-detect PID (default: ${COMM_DEFAULT})
  -b PATH         Target binary path (default: /proc/<pid>/exe)
  -l LIBS         Extra shared libs to trace, comma-separated absolute paths
  --no-bin        Do NOT trace main binary (only trace libs from -l). Useful for -F "*" to avoid zero-size symbols
  --entry         Print function entry events (dtrace pid$target:::entry-like)
  --return        Print function return events (default; includes duration)
  --both          Print both entry + return
  -m MIN_US       Min duration threshold in microseconds (default: 0)
  -d SECONDS      Duration in seconds, 0 means until Ctrl+C (default: 0)
  -o PREFIX       Output prefix (like strace -o). With -ff, outputs: PREFIX.<TID>
  -f 0|1          Split output per TID (emulate strace -ff). Default: 1
  -ff            Alias of --ff (enable split)
  --ff           Enable split (same as -f 1)
  --no-ff        Disable split (same as -f 0)
  -B MODE         bpftrace output buffering: none|full (default: none)
  -q              Quiet mode (default ON)
  -h              Help

Examples:
  ${0##*/} -p 457090 -t 0 -F "anr*" -d 10
  ${0##*/} -p 457090 -t 457098 -F "btree*" -d 10
  ${0##*/} -p 457090 -F "pthread_mutex_lock" -l /usr/lib64/libpthread-2.28.so -d 5
  ${0##*/} -p 457090 -F "btree*" -o /tmp/yas.func -f 1 -d 10
EOF
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 1; }; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Pre-handle -ff/--ff/--no-ff flags (getopts can't parse "-ff" cleanly)
_argv=()
for a in "$@"; do
  case "$a" in
    -ff|--ff) SPLIT_FF="1";;
    --no-ff) SPLIT_FF="0";;
    --no-bin) INCLUDE_BIN="0";;
    --entry) TRACE_MODE="entry";;
    --return) TRACE_MODE="return";;
    --both) TRACE_MODE="both";;
    *) _argv+=("$a");;
  esac
done
set -- "${_argv[@]}"

while getopts ":p:t:c:b:l:F:m:d:o:f:B:qh" opt; do
  case "$opt" in
    p) PID="$OPTARG" ;;
    t) TID="$OPTARG" ;;
    c) COMM="$OPTARG" ;;
    b) BINARY_PATH="$OPTARG" ;;
    l) LIBS="$OPTARG" ;;
    F) FUNC_GLOB="$OPTARG" ;;
    m) MIN_US="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    o) OUT_PREFIX="$OPTARG" ;;
    f) SPLIT_FF="$OPTARG" ;;
    B) BPFTRACE_BUF="$OPTARG" ;;
    q) QUIET="1" ;;
    h) usage; exit 0 ;;
    :) echo "ERROR: -$OPTARG requires a value" >&2; usage; exit 2 ;;
    \?) echo "ERROR: unknown option -$OPTARG" >&2; usage; exit 2 ;;
  esac
done

need_cmd bpftrace
need_cmd ps
need_cmd awk
need_cmd sed
need_cmd pgrep
need_cmd readlink
need_cmd readelf

if [[ -n "$PID" ]] && ! is_uint "$PID"; then echo "ERROR: PID must be a number" >&2; exit 2; fi
if ! is_uint "$TID"; then echo "ERROR: TID must be a number" >&2; exit 2; fi
if ! is_uint "$MIN_US"; then echo "ERROR: MIN_US must be a number" >&2; exit 2; fi
if ! is_uint "$DURATION"; then echo "ERROR: DURATION must be a number" >&2; exit 2; fi
if [[ "$SPLIT_FF" != "0" && "$SPLIT_FF" != "1" ]]; then echo "ERROR: -f must be 0 or 1" >&2; exit 2; fi
if [[ "$BPFTRACE_BUF" != "none" && "$BPFTRACE_BUF" != "full" ]]; then echo "ERROR: -B only supports: none|full" >&2; exit 2; fi
if [[ "$TRACE_MODE" != "return" && "$TRACE_MODE" != "entry" && "$TRACE_MODE" != "both" ]]; then
  echo "ERROR: invalid trace mode: $TRACE_MODE (use --entry|--return|--both)" >&2
  exit 2
fi

if [[ -z "$FUNC_GLOB" ]]; then
  echo "ERROR: -F is required (function glob)" >&2
  usage
  exit 2
fi

if [[ -z "$PID" ]]; then
  PID="$(pgrep -o -x "$COMM" 2>/dev/null || true)"
  if [[ -z "$PID" ]]; then
    PID="$(pgrep -o -f "$COMM" 2>/dev/null || true)"
  fi
  if [[ -z "$PID" ]]; then
    echo "ERROR: process not found (-c $COMM)" >&2
    exit 1
  fi
fi

if ! ps -p "$PID" >/dev/null 2>&1; then
  echo "ERROR: PID $PID does not exist" >&2
  exit 1
fi

if [[ -z "$BINARY_PATH" ]]; then
  BINARY_PATH="$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)"
fi
if [[ "$INCLUDE_BIN" == "1" ]]; then
  if [[ -z "$BINARY_PATH" || ! -f "$BINARY_PATH" ]]; then
    echo "ERROR: cannot resolve binary path (use -b or --no-bin)" >&2
    exit 1
  fi
fi

targets=()
if [[ "$INCLUDE_BIN" == "1" ]]; then
  targets+=("$BINARY_PATH")
fi
if [[ -n "$LIBS" ]]; then
  IFS=',' read -r -a _libs <<<"$LIBS"
  for p in "${_libs[@]}"; do
    p="${p//[[:space:]]/}"
    [[ -z "$p" ]] && continue
    if [[ ! -f "$p" ]]; then
      echo "ERROR: lib not found: $p" >&2
      exit 1
    fi
    targets+=("$p")
  done
fi
if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "ERROR: no targets to trace. Provide -l LIBS or remove --no-bin." >&2
  exit 2
fi

filtered_targets=()
for t in "${targets[@]}"; do
  # Only include targets that actually have at least one matching symbol.
  # Otherwise bpftrace may fail to attach and produce no useful output.
  # IMPORTANT: allow listing even when caller sets BPFTRACE_MAX_PROBES (listing should not be limited)
  first_line="$(env -u BPFTRACE_MAX_PROBES bpftrace -l "uprobe:$t:$FUNC_GLOB" 2>/dev/null | head -1 || true)"
  if [[ -n "$first_line" ]]; then
    filtered_targets+=("$t")
  fi
done
targets=("${filtered_targets[@]}")
if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "ERROR: no uprobe targets matched FUNC_GLOB=\"$FUNC_GLOB\" (check -F/-b/-l)" >&2
  exit 1
fi

BT="/tmp/trace_yashandb_func_${PID}_${TID}_$$.bt"
cleanup() { rm -f "$BT" 2>/dev/null || true; }
trap cleanup EXIT

{
  cat <<'BT'
BEGIN {
  // one-line banner for context
  printf("## trace_yashandb: pid=%d tid=%d min_us=%d\n", __PID__, __TID__, __MIN_US__);
}

// Correlate entry/return using (tid, sp). On AArch64 the stack pointer is restored
// before the return probe fires, so reg("sp") matches entry sp for that call frame.
//
// Print columns:
//   TIME(HH:MM:SS.ffffff)  PID  TID  COMM  FUNC() = 0xRET  <SEC.USEC>
BT

  for t in "${targets[@]}"; do
    if [[ "$FUNC_GLOB" == "*" ]]; then
      # When tracing all functions, avoid zero-size symbols (e.g. register_tm_clones)
      # by enumerating FUNC symbols with Size>0 and generating explicit probes.
      mapfile -t _syms < <(
        readelf -Ws --wide "$t" 2>/dev/null | awk '
          $4=="FUNC" && $3>0 && index($8,"@")==0 { print $8 }' | sort -u
      )
      for sym in "${_syms[@]}"; do
        [[ -z "$sym" ]] && continue
        printf "uprobe:%s:%s / pid==__PID__ && (__TID__==0 || tid==__TID__) / {\n" "$t" "$sym"
        cat <<'BT'
  $sp = reg("sp");
  @ts[tid, $sp] = nsecs;
  @fn[tid, $sp] = func;
  if (__MODE_ENTRY__) {
    printf("%s %-6d %-6d %-16s %s()\n",
           strftime("%H:%M:%S.%f", nsecs), pid, tid, comm, func);
  }
}
BT
        printf "uretprobe:%s:%s / pid==__PID__ && (__TID__==0 || tid==__TID__) / {\n" "$t" "$sym"
        cat <<'BT'
  $sp = reg("sp");
  $t0 = @ts[tid, $sp];
  if ($t0) {
    $dns = nsecs - $t0;
    $dus = $dns / 1000;
    if (__MODE_RETURN__ && $dus >= __MIN_US__) {
      $ds = $dus / 1000000;
      $dusr = $dus % 1000000;
      printf("%s %-6d %-6d %-16s %s() = 0x%lx <%lld.%06lld>\n",
             strftime("%H:%M:%S.%f", nsecs), pid, tid, comm, @fn[tid, $sp], retval, $ds, $dusr);
    }
    delete(@ts[tid, $sp]);
    delete(@fn[tid, $sp]);
  }
}
BT
      done
    else
      printf "uprobe:%s:%s / pid==__PID__ && (__TID__==0 || tid==__TID__) / {\n" "$t" "$FUNC_GLOB"
      cat <<'BT'
  $sp = reg("sp");
  @ts[tid, $sp] = nsecs;
  @fn[tid, $sp] = func;
  if (__MODE_ENTRY__) {
    printf("%s %-6d %-6d %-16s %s()\n",
           strftime("%H:%M:%S.%f", nsecs), pid, tid, comm, func);
  }
}
BT
      printf "uretprobe:%s:%s / pid==__PID__ && (__TID__==0 || tid==__TID__) / {\n" "$t" "$FUNC_GLOB"
      cat <<'BT'
  $sp = reg("sp");
  $t0 = @ts[tid, $sp];
  if ($t0) {
    $dns = nsecs - $t0;
    $dus = $dns / 1000;
    if (__MODE_RETURN__ && $dus >= __MIN_US__) {
      $ds = $dus / 1000000;
      $dusr = $dus % 1000000;
      printf("%s %-6d %-6d %-16s %s() = 0x%lx <%lld.%06lld>\n",
             strftime("%H:%M:%S.%f", nsecs), pid, tid, comm, @fn[tid, $sp], retval, $ds, $dusr);
    }
    delete(@ts[tid, $sp]);
    delete(@fn[tid, $sp]);
  }
}
BT
    fi
  done

  cat <<'BT'
END {
  clear(@ts);
  clear(@fn);
}
BT
} >"$BT"

sed -i.bak \
  -e "s/__PID__/$PID/g" \
  -e "s/__TID__/$TID/g" \
  -e "s/__MIN_US__/$MIN_US/g" \
  -e "s/__MODE_ENTRY__/$([[ \"$TRACE_MODE\" == \"entry\" || \"$TRACE_MODE\" == \"both\" ]] && echo 1 || echo 0)/g" \
  -e "s/__MODE_RETURN__/$([[ \"$TRACE_MODE\" == \"return\" || \"$TRACE_MODE\" == \"both\" ]] && echo 1 || echo 0)/g" \
  "$BT"
rm -f "${BT}.bak" 2>/dev/null || true

cmd=(bpftrace)
if [[ "$QUIET" == "1" ]]; then cmd+=(-q); fi
cmd+=(-B "$BPFTRACE_BUF" "$BT")

run_stream() {
  if [[ "$DURATION" -gt 0 ]]; then
    timeout "$DURATION" "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

if [[ "$SPLIT_FF" == "1" && -n "$OUT_PREFIX" ]]; then
  run_stream | awk -v pfx="$OUT_PREFIX" '
    /^## / { next }
    /^$/ { next }
    {
      # Column 3 is TID
      tid = $3;
      if (tid == "" || tid !~ /^[0-9]+$/) { tid = "unknown"; }
      fn = pfx "." tid;
      print $0 >> fn;
      fflush(fn);
    }'
elif [[ "$SPLIT_FF" == "1" && -z "$OUT_PREFIX" ]]; then
  run_stream
else
  if [[ -n "$OUT_PREFIX" ]]; then
    run_stream >"$OUT_PREFIX"
  else
    run_stream
  fi
fi


