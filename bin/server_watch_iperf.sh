#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

TMP_ROOT="${BASE_DIR}/tmp"
mkdir -p "$TMP_ROOT"
mkdir -p "${BASE_DIR}/${LOG_ROOT}"

CURRENT_OUTFILE="$TMP_ROOT/server_current_outdir"

detect_active_client_ip() {
  ss -Htn "sport = :$SERVER_PORT" 2>/dev/null | \
  awk '$1 == "ESTAB" {print $5}' | \
  while read -r peer; do
    if [[ "$peer" =~ ^\[.*\]:[0-9]+$ ]]; then
      peer="${peer#\[}"
      peer="${peer%\]:*}"
    else
      peer="${peer%:*}"
    fi
    echo "$peer"
    break
  done
}

echo "[INFO] server_watch_iperf started: port=$SERVER_PORT iface=$SERVER_IFACE"

while true; do
  # 이미 활성 run이 있으면 run_server가 current_outdir를 지울 때까지 대기
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

    echo "[INFO] detected iperf control flow from $PEER_IP -> start monitor: $EXP_ID"

    # protocol/direction은 아직 미정
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