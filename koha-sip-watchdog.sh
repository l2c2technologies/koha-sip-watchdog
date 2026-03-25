#!/bin/bash
# koha-sip-watchdog.sh — detect and fix orphaned/pipe-blocked Koha SIP workers
# Usage: koha-sip-watchdog.sh [--dry-run|--fix] [--log FILE]
# Only acts on instances with /var/lib/koha/<instance>/sip.enabled

set -euo pipefail

MODE="dry-run"
LOG_FILE="/var/log/koha/koha-sip-watchdog.log"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        --fix)     MODE="fix" ;;
        --log)     LOG_FILE="$2"; shift ;;
        *) echo "Usage: $0 [--dry-run|--fix] [--log FILE]"; exit 1 ;;
    esac
    shift
done

[[ $EUID -ne 0 ]] && { echo "ERROR: run as root"; exit 1; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" | tee -a "$LOG_FILE"; }

TOTAL=0

for INSTANCE in $(koha-list 2>/dev/null); do
    [[ -f "/var/lib/koha/${INSTANCE}/sip.enabled" ]] || continue

    DAEMON_PID=$(pgrep -f "daemon --name=${INSTANCE}-koha-sip" 2>/dev/null || true)
    [[ -z "$DAEMON_PID" ]] && { log WARN "$INSTANCE: SIP daemon not running"; continue; }

    ZOMBIES=$(ps -eo pid,ppid,stat | awk -v d="$DAEMON_PID" '$2==d && $3~/^Z/ {print $1}' || true)
    ORPHANS=$(ps -eo pid,ppid,wchan,cmd | grep "${INSTANCE}-koha-sip" | grep -v "daemon\|grep" \
              | awk '$2==1 || $3=="pipe_w" {print $1}' | sort -u || true)

    [[ -z "$ZOMBIES" && -z "$ORPHANS" ]] && { log INFO "$INSTANCE: OK"; continue; }

    ISSUES=$(echo -e "$ZOMBIES\n$ORPHANS" | grep -c '[0-9]' || true)
    TOTAL=$((TOTAL + ISSUES))
    log WARN "$INSTANCE: $ISSUES issue(s) — zombies=$(echo $ZOMBIES|tr '\n' ' ') orphans/blocked=$(echo $ORPHANS|tr '\n' ' ')"

    if [[ "$MODE" == "fix" ]]; then
        echo "$ORPHANS" | xargs -r kill -9 2>/dev/null || true
        kill -9 "$DAEMON_PID" 2>/dev/null || true
        sleep 2
        pgrep -f "koha-sip.*${INSTANCE}" | xargs -r kill -9 2>/dev/null || true
        sleep 1
        koha-sip --start "$INSTANCE" >> "$LOG_FILE" 2>&1 \
            && log INFO "$INSTANCE: restarted OK" \
            || log ERROR "$INSTANCE: restart failed — check manually"
    else
        log INFO "$INSTANCE: [DRY-RUN] would kill PIDs $(echo -e "$ORPHANS\n$DAEMON_PID" | tr '\n' ' ') then koha-sip --start"
    fi
done

[[ $TOTAL -eq 0 ]] && log INFO "All SIP-enabled instances healthy" \
                    || log WARN "Total issues: $TOTAL — mode=$MODE"
