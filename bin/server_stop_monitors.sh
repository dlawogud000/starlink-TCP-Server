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
    pid="$(cat "$file")"
    kill "-$sig" "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$file"
  fi
}

stop_pidfile "$TMP_ROOT/server_ss_parse.pid" TERM
stop_pidfile "$TMP_ROOT/server_ss.pid" TERM
stop_pidfile "$TMP_ROOT/server_iface.pid" TERM
stop_pidfile "$TMP_ROOT/server_tcpdump.pid" INT