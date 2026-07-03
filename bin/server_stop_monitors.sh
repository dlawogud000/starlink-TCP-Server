#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

stop_pidfile() {
  local file="$1"
  local sig="${2:-TERM}"

  if [ -f "$file" ]; then
    local pid
    pid="$(cat "$file" 2>/dev/null || true)"

    if [ -n "$pid" ]; then
      kill "-$sig" -- "-$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi

    rm -f "$file"
  fi
}

stop_pidfile "$TMP_ROOT/server_ss_parse.pid" TERM
stop_pidfile "$TMP_ROOT/server_ss.pid" TERM
stop_pidfile "$TMP_ROOT/server_iface.pid" TERM
stop_pidfile "$TMP_ROOT/server_tcpdump.pid" INT
stop_pidfile "$TMP_ROOT/server_rtt.pid" TERM

# Fallback cleanup. Keep patterns interface/port-scoped to avoid killing unrelated jobs.
sudo pkill -f "tcpdump -i $SERVER_IFACE" 2>/dev/null || true
sudo pkill -f "ss -tin" 2>/dev/null || true
if [ -n "${APP_RTT_PORT:-}" ]; then
  pkill -f "tcp_ping_sender.*${APP_RTT_PORT}" 2>/dev/null || true
fi