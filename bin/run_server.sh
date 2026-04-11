#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

TMP_ROOT="${BASE_DIR}/tmp"
mkdir -p "$TMP_ROOT"
mkdir -p "${BASE_DIR}/${LOG_ROOT}"

WATCHER_PID=""
IPERF_PID=""
STOP_REQUESTED=0
CURRENT_OUTFILE="$TMP_ROOT/server_current_outdir"

reset_state() {
  rm -f "$CURRENT_OUTFILE"
  rm -f "$TMP_ROOT/server_iperf_tmp.json" "$TMP_ROOT/server_iperf_tmp.stderr.log"
  rm -f "$TMP_ROOT/server_tcpdump.pid" \
        "$TMP_ROOT/server_ss.pid" \
        "$TMP_ROOT/server_ss_parse.pid" \
        "$TMP_ROOT/server_iface.pid"
}

stop_all_monitors() {
  bash "$BASE_DIR/bin/server_stop_monitors.sh" || true
}

wait_for_outdir() {
  local timeout_sec="${1:-10}"
  local waited=0

  while [ "$waited" -lt "$timeout_sec" ]; do
    if [ -f "$CURRENT_OUTFILE" ]; then
      local out_dir
      out_dir="$(cat "$CURRENT_OUTFILE" 2>/dev/null || true)"
      if [ -n "$out_dir" ] && [ -d "$out_dir" ]; then
        echo "$out_dir"
        return 0
      fi
    fi
    [ "$STOP_REQUESTED" -eq 1 ] && return 1
    sleep 0.2
    waited=$((waited + 1))
  done

  return 1
}

read_iperf_info() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f:
    data = json.load(f)
ts = data.get("start", {}).get("test_start", {})
protocol = str(ts.get("protocol", "unknown")).lower()
reverse = int(ts.get("reverse", 0))
direction = "downlink" if reverse == 1 else "uplink"
print(protocol)
print(direction)
PY
}

read_meta_client_ip() {
  local meta_file="$1"
  sed -n 's/^client_ip=//p' "$meta_file" | head -n1
}

rename_outdir_with_result() {
  local out_dir="$1"
  local protocol="$2"
  local direction="$3"

  local base_parent
  base_parent="$(dirname "$out_dir")"

  local base_name
  base_name="$(basename "$out_dir")"   # ex: 20260407_120000_pending_auto
  local ts
  ts="${base_name%%_pending_*}"

  local new_dir="${base_parent}/${ts}_${protocol}_${direction}_auto"

  # 이미 존재하면 suffix 추가
  local idx=1
  local final_dir="$new_dir"
  while [ -e "$final_dir" ] && [ "$final_dir" != "$out_dir" ]; do
    final_dir="${new_dir}_dup${idx}"
    idx=$((idx + 1))
  done

  if [ "$final_dir" != "$out_dir" ]; then
    mv "$out_dir" "$final_dir"
  fi

  echo "$final_dir"
}

plot_server_graphs() {
  local OUT_DIR="$1"
  local PROTOCOL="$2"

  echo "[INFO] Generating server plots for $OUT_DIR ..."

  if [ -f "$OUT_DIR/server_iperf.json" ] || [ -f "$OUT_DIR/iperf.json" ]; then
    python3 "$BASE_DIR/graph/server_iperf.py" "$OUT_DIR" \
      > "$OUT_DIR/plot_server_iperf.stdout.log" 2>&1 || true
  fi

  if [ "$PROTOCOL" = "tcp" ]; then
    python3 "$BASE_DIR/graph/server_tcpinfo.py" "$OUT_DIR" \
      > "$OUT_DIR/plot_server_tcpinfo.stdout.log" 2>&1 || true
  fi
}

shutdown_handler() {
  STOP_REQUESTED=1
  echo "[INFO] Shutdown requested. Cleaning up..."

  if [ -n "${IPERF_PID:-}" ]; then
    kill -INT "$IPERF_PID" 2>/dev/null || true
    wait "$IPERF_PID" 2>/dev/null || true
    IPERF_PID=""
  fi

  if [ -n "${WATCHER_PID:-}" ]; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
    WATCHER_PID=""
  fi

  stop_all_monitors
  reset_state
  exit 0
}

cleanup_on_exit() {
  stop_all_monitors || true
  reset_state || true

  if [ -n "${WATCHER_PID:-}" ]; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
}

trap shutdown_handler INT TERM
trap cleanup_on_exit EXIT

reset_state
stop_all_monitors || true

echo "[INFO] Starting server watcher ..."
bash "$BASE_DIR/bin/server_watch_iperf.sh" &
WATCHER_PID=$!

echo "[INFO] Starting iperf3 one-shot server loop on port $SERVER_PORT"

while true; do
  [ "$STOP_REQUESTED" -eq 1 ] && break

  reset_state

  iperf3 -s -p "$SERVER_PORT" -4 -1 --json \
    > "$TMP_ROOT/server_iperf_tmp.json" \
    2> "$TMP_ROOT/server_iperf_tmp.stderr.log" &
  IPERF_PID=$!

  wait "$IPERF_PID" || true
  IPERF_PID=""

  [ "$STOP_REQUESTED" -eq 1 ] && break

  OUT_DIR=""
  if OUT_DIR="$(wait_for_outdir 30)"; then
    mv "$TMP_ROOT/server_iperf_tmp.json" "$OUT_DIR/server_iperf.json" 2>/dev/null || true
    mv "$TMP_ROOT/server_iperf_tmp.stderr.log" "$OUT_DIR/server_iperf.stderr.log" 2>/dev/null || true

    # iperf JSON 기준으로 protocol/direction 확정
    mapfile -t INFO < <(read_iperf_info "$OUT_DIR/server_iperf.json")
    PROTOCOL="${INFO[0]:-unknown}"
    DIRECTION="${INFO[1]:-unknown}"

    CLIENT_IP="$(read_meta_client_ip "$OUT_DIR/meta.txt" || true)"
    CLIENT_IP="${CLIENT_IP:-unknown}"

    FINAL_OUT_DIR="$(rename_outdir_with_result "$OUT_DIR" "$PROTOCOL" "$DIRECTION")"

    # meta 다시 정확하게 기록
    bash "$BASE_DIR/bin/server_collect_meta.sh" \
      "$PROTOCOL" "$DIRECTION" "auto" "$FINAL_OUT_DIR" "$CLIENT_IP" "-"

    echo "[INFO] Saved iperf server result to $FINAL_OUT_DIR/server_iperf.json"

    stop_all_monitors
    plot_server_graphs "$FINAL_OUT_DIR" "$PROTOCOL"
    reset_state
  else
    echo "[WARN] Missing OUT_DIR for this run. Cleaning state without orphan folder."
    stop_all_monitors
    reset_state
  fi

  sleep 0.5
done