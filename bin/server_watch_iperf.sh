#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

TMP_ROOT="${BASE_DIR}/tmp"
mkdir -p "$TMP_ROOT"
mkdir -p "${BASE_DIR}/${LOG_ROOT}"

CURRENT_OUTFILE="$TMP_ROOT/server_current_outdir"

normalize_ports() {
  local s="${1:-}"
  s="${s//,/ }"
  for p in $s; do
    [[ -n "$p" ]] && echo "$p"
  done
}

build_ss_filter() {
  local filter=""
  local p
  for p in $(normalize_ports "${SERVER_PORTS:-$SERVER_PORT}"); do
    if [ -z "$filter" ]; then
      filter="sport = :$p"
    else
      filter="$filter or sport = :$p"
    fi
  done
  echo "$filter"
}

strip_peer_ip() {
  local peer="$1"
  if [[ "$peer" =~ ^\[.*\]:[0-9]+$ ]]; then
    peer="${peer#\[}"
    peer="${peer%\]:*}"
  else
    peer="${peer%:*}"
  fi
  echo "$peer"
}

detect_active_client_ip() {
  local filter
  filter="$(build_ss_filter)"
  ss -Htn "$filter" 2>/dev/null | \
  awk '$1 == "ESTAB" {print $5}' | \
  while read -r peer; do
    strip_peer_ip "$peer"
    break
  done
}

echo "[INFO] server_watch_iperf started: ports=${SERVER_PORTS:-$SERVER_PORT} iface=$SERVER_IFACE"

while true; do
  if [ -f "$CURRENT_OUTFILE" ]; then
    sleep 0.2
    continue
  fi

  PEER_IP="$(detect_active_client_ip || true)"
  if [ -n "$PEER_IP" ]; then
    TS="$(date +%Y%m%d_%H%M%S)"
    RUN_ID="auto"
    EXP_ID="${TS}_pending_${RUN_ID}"
    OUT_DIR="${BASE_DIR}/${LOG_ROOT}/${EXP_ID}"

    mkdir -p "$OUT_DIR"
    echo "$OUT_DIR" > "$CURRENT_OUTFILE"

    echo "[INFO] detected iperf flow from $PEER_IP -> start monitor: $EXP_ID"

    bash "$BASE_DIR/bin/server_collect_meta.sh" \
      "unknown" "unknown" "$RUN_ID" "$OUT_DIR" "$PEER_IP" "-"

    bash "$BASE_DIR/bin/sync_time_check.sh" > "$OUT_DIR/time_sync.txt" 2>&1 || true
    bash "$BASE_DIR/bin/server_start_monitors.sh" "$OUT_DIR" "$PEER_IP"

    while [ -f "$CURRENT_OUTFILE" ]; do
      sleep 0.2
    done
  fi

  sleep 0.2
done