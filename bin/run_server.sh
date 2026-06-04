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
  rm -f "$TMP_ROOT/server_tcpdump_tmp.pcap" "$TMP_ROOT/server_tcpdump_tmp.log"
  rm -f "$TMP_ROOT/server_tcpdump.pid" \
        "$TMP_ROOT/server_ss.pid" \
        "$TMP_ROOT/server_ss_parse.pid" \
        "$TMP_ROOT/server_iface.pid"
}

stop_all_monitors() {
  bash "$BASE_DIR/bin/server_stop_monitors.sh" || true
}

stop_tcpdump_only() {
  if [ -f "$TMP_ROOT/server_tcpdump.pid" ]; then
    local pid
    pid="$(cat "$TMP_ROOT/server_tcpdump.pid" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill -INT "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$TMP_ROOT/server_tcpdump.pid"
  fi
}

start_early_tcpdump() {
  # Keep the existing variable name SERVER_PORTS because this project config uses it.
  # In the current single-port server mode, SERVER_PORTS should contain one port.
  local filter="port $SERVER_PORT"

  echo "[INFO] Starting early tcpdump: $filter"
  sudo setsid tcpdump -i "$SERVER_IFACE" -s "$TCPDUMP_SNAPLEN" \
    -w "$TMP_ROOT/server_tcpdump_tmp.pcap" \
    "$filter" \
    > "$TMP_ROOT/server_tcpdump_tmp.log" 2>&1 &
  echo $! > "$TMP_ROOT/server_tcpdump.pid"

  sleep "${TCPDUMP_WARMUP_SEC:-1}"
}

move_early_tcpdump_to_outdir() {
  local out_dir="$1"

  if [ -f "$TMP_ROOT/server_tcpdump_tmp.pcap" ]; then
    mv -f "$TMP_ROOT/server_tcpdump_tmp.pcap" "$out_dir/server_tcpdump.pcap"
  fi

  if [ -f "$TMP_ROOT/server_tcpdump_tmp.log" ]; then
    mv -f "$TMP_ROOT/server_tcpdump_tmp.log" "$out_dir/tcpdump_stdout.log"
  fi
}

move_iperf_to_outdir() {
  local out_dir="$1"

  if [ -f "$TMP_ROOT/server_iperf_tmp.json" ]; then
    mv -f "$TMP_ROOT/server_iperf_tmp.json" "$out_dir/server_iperf.json"
  fi

  if [ -f "$TMP_ROOT/server_iperf_tmp.stderr.log" ]; then
    mv -f "$TMP_ROOT/server_iperf_tmp.stderr.log" "$out_dir/server_iperf.stderr.log"
  fi
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
    sleep 0.5
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
  if [ -f "$meta_file" ]; then
    sed -n 's/^client_ip=//p' "$meta_file" | head -n1
  fi
}

rename_outdir_with_result() {
  local out_dir="$1"
  local protocol="$2"
  local direction="$3"

  local base_parent
  base_parent="$(dirname "$out_dir")"

  local base_name
  base_name="$(basename "$out_dir")"
  local ts
  ts="${base_name%%_pending_*}"

  local new_dir="${base_parent}/${ts}_${protocol}_${direction}_auto"

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

  if [ "$PROTOCOL" = "tcp" ]; then
    python3 "$BASE_DIR/graph/retransmission.py" "$OUT_DIR/ss_tcpinfo.log" \
      > "$OUT_DIR/plot_retransmission.stdout.log" 2>&1 || true
  fi

  python3 "$BASE_DIR/graph/iperf_jsh.py" "$OUT_DIR" \
    > "$OUT_DIR/plot_iperf.stdout.log" 2>&1 || true
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
  if [ -n "${IPERF_PID:-}" ]; then
    kill -INT "$IPERF_PID" 2>/dev/null || true
    wait "$IPERF_PID" 2>/dev/null || true
  fi

  if [ -n "${WATCHER_PID:-}" ]; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi

  stop_all_monitors || true
  reset_state || true
}

trap shutdown_handler INT TERM
trap cleanup_on_exit EXIT

reset_state
stop_all_monitors || true

echo "[INFO] Starting server watcher ..."
bash "$BASE_DIR/bin/server_watch_iperf.sh" &
WATCHER_PID=$!

echo "[INFO] Starting iperf3 one-shot server loop on port $SERVER_PORT"

while [ "$STOP_REQUESTED" -eq 0 ]; do
  reset_state
  IPERF_PID=""

  start_early_tcpdump

  echo "[INFO] Starting iperf3 server on port $SERVER_PORT"
  iperf3 -s -p "$SERVER_PORT" -4 -1 -i "$IPERF_INTERVAL" --json \
    > "$TMP_ROOT/server_iperf_tmp.json" \
    2> "$TMP_ROOT/server_iperf_tmp.stderr.log" &
  IPERF_PID=$!

  wait "$IPERF_PID" || true
  IPERF_PID=""

  [ "$STOP_REQUESTED" -eq 1 ] && exit 0

  OUT_DIR=""
  if OUT_DIR="$(wait_for_outdir 30)"; then
    # Stop tcpdump explicitly first to flush the pcap.
    # Do not call reset_state before moving tmp outputs.
    stop_tcpdump_only

    move_early_tcpdump_to_outdir "$OUT_DIR"
    move_iperf_to_outdir "$OUT_DIR"

    if [ -s "$OUT_DIR/server_iperf.json" ]; then
      mapfile -t INFO < <(read_iperf_info "$OUT_DIR/server_iperf.json")
      PROTOCOL="${INFO[0]:-unknown}"
      DIRECTION="${INFO[1]:-unknown}"
    else
      PROTOCOL="unknown"
      DIRECTION="unknown"
    fi

    CLIENT_IP="$(read_meta_client_ip "$OUT_DIR/meta.txt" || true)"
    CLIENT_IP="${CLIENT_IP:-unknown}"

    FINAL_OUT_DIR="$(rename_outdir_with_result "$OUT_DIR" "$PROTOCOL" "$DIRECTION")"

    bash "$BASE_DIR/bin/server_collect_meta.sh" \
      "$PROTOCOL" "$DIRECTION" "auto" "$FINAL_OUT_DIR" "$CLIENT_IP" "-"

    echo "[INFO] Saved iperf server result to $FINAL_OUT_DIR/server_iperf.json"

    # Stop ss/iface monitors after rename; their file descriptors keep writing
    # to the same files even after directory rename.
    stop_all_monitors

    plot_server_graphs "$FINAL_OUT_DIR" "$PROTOCOL"

    reset_state
  else
    echo "[WARN] Missing OUT_DIR for this run. Cleaning state without orphan folder."
    stop_all_monitors || true
    reset_state
  fi
done