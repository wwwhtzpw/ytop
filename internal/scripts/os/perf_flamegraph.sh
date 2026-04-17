#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./perf_flamegraph.sh -p <pid> -s <seconds>
#   ./perf_flamegraph.sh -p yashan -s <seconds>  # auto-detect yasdb PID by keyword: "yasdb open"
#   ./perf_flamegraph.sh -d <base_dir_or_flamegraph_dir> -p <pid|yashan|all> -s <seconds>
#   ./perf_flamegraph.sh -t <tid> -s <seconds>   # record a single thread (TID)
#   ./perf_flamegraph.sh -f <perf.data> [-d <base_dir_or_flamegraph_dir>]   # analyze existing perf.data
#   ./perf_flamegraph.sh -s <seconds>            # default: -p yashan
#   ./perf_flamegraph.sh --help
#
# Directory policy:
# - If /data/yashan exists: use /data/yashan/FlameGraph as the FlameGraph root
# - Otherwise: fallback to /FlameGraph
# - Output goes to <FlameGraph root>/perf_data

DEFAULT_SLEEP=10

# Defaults requested:
# -p: yashan
# -d: /data/yashan
PID="yashan"
SLEEP=""
FLAMEGRAPH_BASE_DIR="/data/yashan"
D_SPECIFIED="false"
P_SPECIFIED="false"
S_SPECIFIED="false"
T_SPECIFIED="false"
PERF_DATA_FILE=""
TID=""

print_help() {
  cat <<'EOF'
perf_flamegraph.sh - record perf samples and (optionally) generate a FlameGraph SVG

Usage:
  perf_flamegraph.sh [-d <base_dir_or_flamegraph_dir>] [-p <pid|yashan|all>] [-s <seconds>]
  perf_flamegraph.sh [-d <base_dir_or_flamegraph_dir>] -t <tid> [-s <seconds>]
  perf_flamegraph.sh -f <perf.data> [-d <base_dir_or_flamegraph_dir>]
  perf_flamegraph.sh -h|--help

Options:
  -p <pid|yashan|all>
                   Target PID.
                   - yashan (default): auto-detect yasdb PID by keyword: "yasdb open"
                   - all: system-wide recording (perf record -a)
                   If multiple PIDs match for "yashan", the script will list them and pick the first one.
  -t <tid>          Target thread ID (TID). Record a single thread only.
                   Note: -t is mutually exclusive with -p.
  -s <seconds>      Recording duration in seconds. Default: 10
  -f <perf.data>    Analyze an existing perf.data (skip recording). Note: -f is mutually exclusive with -p/-s.
  -d <dir>          Directory for FlameGraph & outputs. Default: /data/yashan
                   If <dir> already contains flamegraph.pl (or FlameGraph-master/flamegraph.pl), it is treated
                   as the FlameGraph directory. Otherwise, the script will use <dir>/FlameGraph.
  -h, --help        Show this help.

Default FlameGraph directory behavior (when -d is not specified):
  - Use /data/yashan/FlameGraph if /data/yashan exists, otherwise fallback to /FlameGraph

Outputs (under <FlameGraph root>/perf_data):
  - perf.data       perf record output
  - perf.unfolded   perf script output
  - perf.folded     collapsed stacks for FlameGraph
  - perf.svg        generated FlameGraph (if FlameGraph tools are present)
EOF
}

# Manual argv parsing to support --help
while [[ $# -gt 0 ]]; do
  case "$1" in
  -p)
    PID="${2:-}"
    P_SPECIFIED="true"
    shift 2
    ;;
  -t)
    TID="${2:-}"
    T_SPECIFIED="true"
    shift 2
    ;;
  -s)
    SLEEP="${2:-}"
    S_SPECIFIED="true"
    shift 2
    ;;
  -f)
    PERF_DATA_FILE="${2:-}"
    shift 2
    ;;
  -d)
    FLAMEGRAPH_BASE_DIR="${2:-}"
    D_SPECIFIED="true"
    shift 2
    ;;
  -h|--help)
    print_help
    exit 0
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "ERROR: unknown argument: $1"
    echo ""
    print_help
    exit 1
    ;;
  esac
done

if [[ -z "${SLEEP}" ]]; then
  SLEEP="${DEFAULT_SLEEP}"
fi

if [[ "${D_SPECIFIED}" != "true" && ! -d "${FLAMEGRAPH_BASE_DIR}" ]]; then
  # Keep previous fallback behavior for machines without /data/yashan
  FLAMEGRAPH_ROOT="/FlameGraph"
else
  # - If the provided dir already looks like a FlameGraph dir, use it as-is
  # - Otherwise use <dir>/FlameGraph
  if [[ -f "${FLAMEGRAPH_BASE_DIR}/flamegraph.pl" || -f "${FLAMEGRAPH_BASE_DIR}/FlameGraph-master/flamegraph.pl" ]]; then
    FLAMEGRAPH_ROOT="${FLAMEGRAPH_BASE_DIR}"
  else
    FLAMEGRAPH_ROOT="${FLAMEGRAPH_BASE_DIR%/}/FlameGraph"
  fi
fi

# 兼容常见目录结构：有的人会把仓库放在 FlameGraph-master 子目录
if [[ -f "${FLAMEGRAPH_ROOT}/flamegraph.pl" ]]; then
  FLAMEGRAPH_DIR="${FLAMEGRAPH_ROOT}"
elif [[ -f "${FLAMEGRAPH_ROOT}/FlameGraph-master/flamegraph.pl" ]]; then
  FLAMEGRAPH_DIR="${FLAMEGRAPH_ROOT}/FlameGraph-master"
else
  # 兜底：即便不存在，也把“期望目录”设置好，便于打印分析命令
  FLAMEGRAPH_DIR="${FLAMEGRAPH_ROOT}"
fi

OUTPUT_DIR="${FLAMEGRAPH_ROOT}/perf_data"
mkdir -p "${OUTPUT_DIR}"

# 生成带主机名和时间戳的文件名前缀（两种模式共用）
HOSTNAME="$(hostname)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
FILE_PREFIX="perf_${HOSTNAME}_${TIMESTAMP}"

PERF_DATA="${OUTPUT_DIR}/${FILE_PREFIX}.data"
PERF_UNFOLDED="${OUTPUT_DIR}/${FILE_PREFIX}.unfolded"
PERF_FOLDED="${OUTPUT_DIR}/${FILE_PREFIX}.folded"
PERF_SVG="${OUTPUT_DIR}/${FILE_PREFIX}.svg"

run_as_root_or_sudo() {
  # Run a command as root when possible:
  # - If already root: run directly
  # - Otherwise: use sudo
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_perl_open_fallback() {
  # flamegraph.pl uses: "use open qw(:std :utf8);"
  # On some minimal systems, open.pm is not installed. If so, provide a minimal fallback
  # open.pm via PERL5LIB (no need to touch system packages).
  if perl -e 'use open; 1' >/dev/null 2>&1; then
    return 0
  fi

  OPEN_FALLBACK_DIR="$(mktemp -d)"
  export PERL5LIB="${OPEN_FALLBACK_DIR}${PERL5LIB:+:${PERL5LIB}}"
  cat >"${OPEN_FALLBACK_DIR}/open.pm" <<'EOF'
package open;
use strict;
use warnings;

# Minimal fallback for "use open qw(:std :utf8);" used by FlameGraph.
# This is NOT a full implementation of the core pragma; it only sets UTF-8 on std handles.
sub import {
  my ($class, @args) = @_;
  my $std  = grep { $_ eq ':std' } @args;
  my $utf8 = grep { $_ eq ':utf8' || $_ eq ':encoding(UTF-8)' } @args;
  return unless $std;
  return unless $utf8;
  eval { binmode(STDIN,  ':utf8'); 1; };
  eval { binmode(STDOUT, ':utf8'); 1; };
  eval { binmode(STDERR, ':utf8'); 1; };
  return;
}

1;
EOF
}

resolve_pid_if_needed() {
  # If user passes -p yashan, auto-detect yasdb PID(s) by keyword.
  if [[ "${PID}" == "all" ]]; then
    PID=""
    return 0
  fi
  if [[ "${PID}" == "yashan" ]]; then
    local keyword="yasdb open"
    local pids=""
    pids="$(pgrep -f "${keyword}" || true)"
    if [[ -z "${pids}" ]]; then
      echo "ERROR: -p yashan specified, but no process matched keyword: ${keyword}"
      echo "Hint: run 'ps -ef | grep -i \"${keyword}\"' to confirm the process command line."
      exit 1
    fi

    # If multiple PIDs matched, pick the first one but print all for visibility.
    local first_pid=""
    first_pid="$(echo "${pids}" | head -n 1)"
    if [[ "$(echo "${pids}" | wc -l | tr -d ' ')" -gt 1 ]]; then
      echo "WARNING: multiple PIDs matched keyword: ${keyword}"
      echo "${pids}" | sed 's/^/  - /'
      echo "INFO: defaulting to PID=${first_pid}. If you want a different one, pass -p <pid> explicitly."
    else
      echo "INFO: auto-detected yasdb PID=${first_pid} by keyword: ${keyword}"
    fi
    PID="${first_pid}"
  fi
}

if [[ -n "${PERF_DATA_FILE}" ]]; then
  # -f mode: analyze existing perf.data, mutually exclusive with recording options
  if [[ "${P_SPECIFIED}" == "true" || "${S_SPECIFIED}" == "true" || "${T_SPECIFIED}" == "true" ]]; then
    echo "ERROR: -f is mutually exclusive with -p/-s/-t. Please use either:"
    echo "  - recording mode:   -p/-s or -t/-s (optional -d)"
    echo "  - analysis mode:    -f (optional -d)"
    exit 1
  fi
  if [[ ! -f "${PERF_DATA_FILE}" ]]; then
    echo "ERROR: perf.data not found: ${PERF_DATA_FILE}"
    exit 1
  fi
  PERF_DATA="${PERF_DATA_FILE}"

  # Put analysis outputs alongside the provided perf.data to avoid confusion.
  PERF_DATA_DIR="$(cd "$(dirname "${PERF_DATA}")" && pwd)"
  # 使用已定义的主机名和时间戳前缀
  PERF_UNFOLDED="${PERF_DATA_DIR}/${FILE_PREFIX}.unfolded"
  PERF_FOLDED="${PERF_DATA_DIR}/${FILE_PREFIX}.folded"
  PERF_SVG="${PERF_DATA_DIR}/${FILE_PREFIX}.svg"

  echo "INFO: analysis-only mode (-f). Skipping perf record."
  echo "INFO: perf.data: ${PERF_DATA}"
else
  # recording mode
  if [[ "${T_SPECIFIED}" == "true" && "${P_SPECIFIED}" == "true" ]]; then
    echo "ERROR: -t is mutually exclusive with -p. Please specify only one target mode."
    exit 1
  fi

  if [[ "${T_SPECIFIED}" == "true" ]]; then
    if [[ -z "${TID}" ]]; then
      echo "ERROR: -t requires a non-empty TID."
      exit 1
    fi
    if [[ ! "${TID}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: invalid TID for -t: ${TID} (must be numeric)"
      exit 1
    fi

    echo "INFO: recording TID=${TID} for ${SLEEP}s"
    echo "Running: perf record -F 99 -g -t \"${TID}\" -o \"${PERF_DATA}\" -- sleep \"${SLEEP}\""
    run_as_root_or_sudo perf record -F 99 -g -t "${TID}" -o "${PERF_DATA}" -- sleep "${SLEEP}"
  else
    resolve_pid_if_needed

    if [[ -z "${PID}" ]]; then
      echo "INFO: no -p specified, recording system-wide for ${SLEEP}s (perf record -a)."
      echo "Running: perf record -F 99 -a -g -o \"${PERF_DATA}\" -- sleep \"${SLEEP}\""
      run_as_root_or_sudo perf record -F 99 -a -g -o "${PERF_DATA}" -- sleep "${SLEEP}"
    else
      echo "INFO: recording PID=${PID} for ${SLEEP}s (all threads by default)"
      echo "Running: perf record -F 99 -g -p \"${PID}\" -o \"${PERF_DATA}\" -- sleep \"${SLEEP}\""
      run_as_root_or_sudo perf record -F 99 -g -p "${PID}" -o "${PERF_DATA}" -- sleep "${SLEEP}"
    fi
  fi
fi

FLAMEGRAPH_PL="${FLAMEGRAPH_DIR}/flamegraph.pl"
COLLAPSE_PL="${FLAMEGRAPH_DIR}/stackcollapse-perf.pl"

if [[ -f "${FLAMEGRAPH_PL}" && -f "${COLLAPSE_PL}" ]]; then
  echo "INFO: FlameGraph tools found at: ${FLAMEGRAPH_DIR}"
  echo "Generating folded stack data..."
  run_as_root_or_sudo perf script -i "${PERF_DATA}" >"${PERF_UNFOLDED}"
  "${COLLAPSE_PL}" --all "${PERF_UNFOLDED}" >"${PERF_FOLDED}"

  echo "Generating flame graph..."
  ensure_perl_open_fallback
  "${FLAMEGRAPH_PL}" "${PERF_FOLDED}" >"${PERF_SVG}"

  echo "INFO: Flame graph generated at: ${PERF_SVG}"
else
  echo "WARNING: FlameGraph tools not found. Skipping auto analysis."
  echo "Expected directory: ${FLAMEGRAPH_DIR}"
  echo "Missing files:"
  [[ -f "${FLAMEGRAPH_PL}" ]] || echo "  - ${FLAMEGRAPH_PL}"
  [[ -f "${COLLAPSE_PL}" ]] || echo "  - ${COLLAPSE_PL}"
  echo ""
  echo "Once FlameGraph is ready (ensure flamegraph.pl and stackcollapse-perf.pl exist), run the following commands to analyze:"
  echo ""
  echo "  sudo perf script -i \"${PERF_DATA}\" >\"${PERF_UNFOLDED}\""
  echo "  \"${COLLAPSE_PL}\" --all \"${PERF_UNFOLDED}\" >\"${PERF_FOLDED}\""
  echo "  \"${FLAMEGRAPH_PL}\" \"${PERF_FOLDED}\" >\"${PERF_SVG}\""
  echo ""
  echo "Output directory: ${OUTPUT_DIR}"
fi


