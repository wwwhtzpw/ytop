#!/bin/bash
#--------------------------------------------------------------------------------
#-- File name:   generate_flamegraph.sh
#-- Purpose:     generate flamegraph svg
#-- Author:      lxy
#-- Usage:       ./generate_flamegraph.sh -p <pid> -s 10(默认收集10s)
#--              FLAMEGRAPH_DIR和OUTPUT_DIR目录要建好，并且先上传FlameGraph-master包
#--------------------------------------------------------------------------------
FLAMEGRAPH_DIR=/FlameGraph/FlameGraph-master
OUTPUT_DIR=/FlameGraph/perf_data

if [ ! -d "$FLAMEGRAPH_DIR" ]; then
  echo "FlameGraph directory not found at $FLAMEGRAPH_DIR"
  exit 1
fi

DEFAULT_SLEEP=10

while getopts "p:s:" opt; do
  case $opt in
  p)
    PID=$OPTARG
    ;;
  s)
    SLEEP=$OPTARG
    ;;
  *)
    echo "Usage: $0 [-p <pid>] [-s <sleep_time>]"
    exit 1
    ;;
  esac
done

if [ -z "$SLEEP" ]; then
  SLEEP=$DEFAULT_SLEEP
fi

if [ -z "$PID" ]; then
  RECORD_CMD="perf record -F 99 -a -g -o $OUTPUT_DIR/perf.data -- sleep $SLEEP"
else
  RECORD_CMD="perf record -F 99 -a -g -p $PID -o $OUTPUT_DIR/perf.data -- sleep $SLEEP"
fi

echo "Running: $RECORD_CMD"
eval $RECORD_CMD

echo "Generating folded stack data..."
perf script -i $OUTPUT_DIR/perf.data >$OUTPUT_DIR/perf.unfolded
$FLAMEGRAPH_DIR/stackcollapse-perf.pl --all $OUTPUT_DIR/perf.unfolded >$OUTPUT_DIR/perf.folded

echo "Generating flame graph..."
$FLAMEGRAPH_DIR/flamegraph.pl $OUTPUT_DIR/perf.folded >$OUTPUT_DIR/perf.svg

echo "Flame graph generated at $OUTPUT_DIR/perf.svg"
