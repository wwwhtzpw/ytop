#!/bin/bash
# ==================================================================
# NOTE: Force to set `oom_score_adj=-1000` for specified processes.
# AUTH: realGuob (guobo@sics.ac.cn)
# DATE: Tue Apr 21 20:06:05 CST 2026
# ==================================================================

# ---------- Configuration ----------
PROCESS_NAMES=("yasdb" "yascsm" "ycscm")
INTERVAL=30
CONFIG_FILE="/etc/default/oom_protect.conf"
# -----------------------------------

# Check if extra-config file exist
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

declare -A PROTECTED_PIDS
declare -A LAST_SET_TIME   # optional: rate-limit logs

# Record log message to syslog daemon
log() {
    echo "$*" >&2
}

# Escape regex special characters for pgrep exact matching
escape_pgrep_pattern() {
    local name="$1"
    # Escape: . [ ] { } ( ) ? * + ^ $ \
    printf '%s' "$name" | sed 's/[.[\*^$+?(){|\\]/\\&/g'
}

# Check if a PID is a zombie process (state Z)
is_zombie() {
    local pid=$1
    local state
    state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ "$state" == "Z" ]]
}

# Set oom_score_adj for a single PID, with retry on transient failure
set_oom_protection() {
    local pid=$1
    local oom_file="/proc/$pid/oom_score_adj"
    local max_retries=2
    local retry=0

    if [[ ! -f "$oom_file" ]]; then
        return 1
    fi

    # Skip zombie processes
    if is_zombie "$pid"; then
        log "Skip the zombie process, PID ${pid}."
        return 1
    fi

    while [[ $retry -lt $max_retries ]]; do
        local current_val
        current_val=$(cat "$oom_file" 2>/dev/null)
        if [[ "$current_val" != "-1000" ]]; then
            printf '%d' -1000 > "$oom_file" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                log "Set PID $pid oom_score_adj = -1000 (was $current_val)."
                PROTECTED_PIDS[$pid]=1
                LAST_SET_TIME[$pid]=$(date +%s)
                return 0
            else
                log "Write failed for PID $pid (retry $((retry+1))/$max_retries)"
                ((retry++))
                sleep 0.2
            fi
        else
            # Already protected
            if [[ -z "${PROTECTED_PIDS[$pid]}" ]]; then
                log "PID $pid already protected (oom_score_adj = -1000)."
                PROTECTED_PIDS[$pid]=1
            fi
            return 0
        fi
    done
    log "Failed to set PID $pid after $max_retries attempts."
    return 1
}

# Clean up records of PIDs that no longer exist or became zombie
cleanup_stale_pids() {
    local current_pids="$1"
    declare -A cur_pid_map
    for pid in $current_pids; do
        cur_pid_map[$pid]=1
    done

    for pid in "${!PROTECTED_PIDS[@]}"; do
        if [[ -z "${cur_pid_map[$pid]}" ]] || is_zombie "$pid"; then
            unset PROTECTED_PIDS[$pid]
            unset LAST_SET_TIME[$pid]
            log "Cleaned up status of PID $pid (exited or zombie)."
        fi
    done
}

# Main loop
main_loop() {
    log "OOM protection daemon started for: ${PROCESS_NAMES[*]}, interval ${INTERVAL}s."

    while true; do
        all_pids=""

        for raw_pname in "${PROCESS_NAMES[@]}"; do
            # Escape regex metacharacters to match literal process name
            pattern=$(escape_pgrep_pattern "$raw_pname")
            pids=$(pgrep -x "$pattern" 2>/dev/null | tr '\n' ' ')
            if [[ -n "$pids" ]]; then
                all_pids="$all_pids $pids"
                for pid in $pids; do
                    set_oom_protection "$pid"
                done
            fi
        done

        cleanup_stale_pids "$all_pids"
        sleep "$INTERVAL"
    done
}

# Signal handler for graceful shutdown
cleanup_exit() {
    log "Received SIGTERM/SIGINT, stopping oom-protect daemon."
    exit 0
}
trap cleanup_exit SIGTERM SIGINT

# Main entry-point for this script
main_loop
