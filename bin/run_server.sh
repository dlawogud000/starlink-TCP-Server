#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

TMP_ROOT="${BASE_DIR}/tmp"
mkdir -p "$TMP_ROOT"
mkdir -p "${BASE_DIR}/${LOG_ROOT}"

WATCHER_PID=""
STOP_REQUESTED=0
CURRENT_OUTFILE="$TMP_ROOT/server_current_outdir"
IPERF_PIDS_FILE="$TMP_ROOT/server_iperf_pids"

normalize_ports() {
  local s="${1:-}"
  s="${s//,/ }"
  for p in $s; do
    [[ -n "$p" ]] && echo "$p"
  done
}

IPERF_PORTS=()
while read -r p; do
  IPERF_PORTS+=("$p")
done < <(normalize_ports "${SERVER_PORTS:-$SERVER_PORT}")

if [ "${#IPERF_PORTS[@]}" -eq 0 ]; then
  IPERF_PORTS=("$SERVER_PORT")
fi

APP_RTT_PORT="${APP_RTT_PORT:-}"
APP_RTT_INTERVAL_MS="${APP_RTT_INTERVAL_MS:-10}"

reset_state() {
  rm -f "$CURRENT_OUTFILE"
  rm -f "$IPERF_PIDS_FILE"
  rm -f "$TMP_ROOT"/server_iperf_tmp_*.json "$TMP_ROOT"/server_iperf_tmp_*.stderr.log
  rm -f "$TMP_ROOT/server_tcpdump_tmp.pcap" "$TMP_ROOT/server_tcpdump_tmp.log"
  rm -f "$TMP_ROOT/server_tcpdump.pid" \
        "$TMP_ROOT/server_ss.pid" \
        "$TMP_ROOT/server_ss_parse.pid" \
        "$TMP_ROOT/server_iface.pid" \
        "$TMP_ROOT/server_rtt.pid"
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

stop_iperf_servers() {
  if [ -f "$IPERF_PIDS_FILE" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill -INT "$pid" 2>/dev/null || true
    done < "$IPERF_PIDS_FILE"

    while read -r pid; do
      [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done < "$IPERF_PIDS_FILE"

    rm -f "$IPERF_PIDS_FILE"
  fi
}

build_tcpdump_filter() {
  local filter=""
  local p
  for p in "${IPERF_PORTS[@]}"; do
    if [ -z "$filter" ]; then
      filter="port $p"
    else
      filter="$filter or port $p"
    fi
  done

  if [ -n "$APP_RTT_PORT" ]; then
    filter="$filter or port $APP_RTT_PORT"
  fi

  echo "$filter"
}

start_early_tcpdump() {
  local filter
  filter="$(build_tcpdump_filter)"

  echo "[INFO] Starting early tcpdump: $filter"
  sudo setsid tcpdump -i "$SERVER_IFACE" -s "$TCPDUMP_SNAPLEN" \
    -w "$TMP_ROOT/server_tcpdump_tmp.pcap" \
    "$filter" \
    > "$TMP_ROOT/server_tcpdump_tmp.log" 2>&1 &
  echo $! > "$TMP_ROOT/server_tcpdump.pid"

  sleep "${TCPDUMP_WARMUP_SEC:-1}"
}

start_rtt_sender() {
  if [ -z "$APP_RTT_PORT" ]; then
    return 0
  fi

  local rtt_bin="$BASE_DIR/bin/app_layer_rtt/tcp_ping_sender"
  if [ ! -x "$rtt_bin" ]; then
    echo "[WARN] app-level RTT binary not executable or not found: $rtt_bin"
    return 0
  fi

  echo "[INFO] Starting app-level RTT sender on port $APP_RTT_PORT"
  setsid "$rtt_bin" "$APP_RTT_PORT" "$APP_RTT_INTERVAL_MS" "$DURATION" "$TMP_ROOT/server_rtt_tmp.csv" \
    > "$TMP_ROOT/server_rtt_tmp.stdout.log" 2>&1 &
  echo $! > "$TMP_ROOT/server_rtt.pid"
}

move_early_tcpdump_to_outdir() {
  local out_dir="$1"

  [ -f "$TMP_ROOT/server_tcpdump_tmp.pcap" ] && mv -f "$TMP_ROOT/server_tcpdump_tmp.pcap" "$out_dir/server_tcpdump.pcap"
  [ -f "$TMP_ROOT/server_tcpdump_tmp.log" ] && mv -f "$TMP_ROOT/server_tcpdump_tmp.log" "$out_dir/tcpdump_stdout.log"
}

move_iperf_to_outdir() {
  local out_dir="$1"
  local p
  for p in "${IPERF_PORTS[@]}"; do
    [ -f "$TMP_ROOT/server_iperf_tmp_${p}.json" ] && mv -f "$TMP_ROOT/server_iperf_tmp_${p}.json" "$out_dir/server_iperf_${p}.json"
    [ -f "$TMP_ROOT/server_iperf_tmp_${p}.stderr.log" ] && mv -f "$TMP_ROOT/server_iperf_tmp_${p}.stderr.log" "$out_dir/server_iperf_${p}.stderr.log"
  done
}

move_rtt_to_outdir() {
  local out_dir="$1"
  [ -f "$TMP_ROOT/server_rtt_tmp.csv" ] && mv -f "$TMP_ROOT/server_rtt_tmp.csv" "$out_dir/server_rtt.csv"
  [ -f "$TMP_ROOT/server_rtt_tmp.stdout.log" ] && mv -f "$TMP_ROOT/server_rtt_tmp.stdout.log" "$out_dir/server_rtt.stdout.log"
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

first_existing_iperf_json() {
  local out_dir="$1"
  local p
  for p in "${IPERF_PORTS[@]}"; do
    if [ -s "$out_dir/server_iperf_${p}.json" ]; then
      echo "$out_dir/server_iperf_${p}.json"
      return 0
    fi
  done
  return 1
}

read_iperf_info() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json, sys
p = sys.argv[1]
try:
    with open(p) as f:
        data = json.load(f)
except Exception:
    print('unknown')
    print('unknown')
    raise SystemExit

ts = data.get('start', {}).get('test_start', {})
protocol = str(ts.get('protocol', 'unknown')).lower()
reverse = int(ts.get('reverse', 0) or 0)
direction = 'downlink' if reverse == 1 else 'uplink'
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

move_server_plot_outputs_for_port() {
  local out_dir="$1"
  local port="$2"

  local f base ext
  for f in \
    "$out_dir/server_iperf3.png" \
    "$out_dir/server_iperf.png" \
    "$out_dir/server_iperf_cdf.png" \
    "$out_dir/iperf3.png" \
    "$out_dir/iperf.png" \
    "$out_dir/iperf_cdf.png" \
    "$out_dir/throughput.png" \
    "$out_dir/throughput_cdf.png"; do
    if [ -f "$f" ]; then
      base="${f%.*}"
      ext="${f##*.}"
      mv -f "$f" "${base}_server_${port}.${ext}"
    fi
  done
}

plot_one_server_iperf_json() {
  local out_dir="$1"
  local json_file="$2"
  local port="$3"

  if [ ! -f "$json_file" ]; then
    return 0
  fi

  local tmp_json="$out_dir/server_iperf.json"
  local backup_json="$out_dir/server_iperf.json.before_multiport_plot"
  local had_backup=0

  if [ -f "$tmp_json" ]; then
    mv -f "$tmp_json" "$backup_json"
    had_backup=1
  fi

  cp -f "$json_file" "$tmp_json"
  python3 "$BASE_DIR/graph/server_iperf.py" "$out_dir" \
    > "$out_dir/plot_server_iperf_${port}.stdout.log" 2>&1 || true
  rm -f "$tmp_json"

  if [ "$had_backup" -eq 1 ]; then
    mv -f "$backup_json" "$tmp_json"
  fi

  move_server_plot_outputs_for_port "$out_dir" "$port"
}

plot_server_graphs() {
  local OUT_DIR="$1"
  local PROTOCOL="$2"

  echo "[INFO] Generating server plots for $OUT_DIR ..."

  local p
  for p in "${IPERF_PORTS[@]}"; do
    plot_one_server_iperf_json "$OUT_DIR" "$OUT_DIR/server_iperf_${p}.json" "$p"
  done

  if [ "$PROTOCOL" = "tcp" ]; then
    python3 "$BASE_DIR/graph/server_tcpinfo.py" "$OUT_DIR" \
      > "$OUT_DIR/plot_server_tcpinfo.stdout.log" 2>&1 || true

    python3 "$BASE_DIR/graph/retransmission.py" "$OUT_DIR" \
      > "$OUT_DIR/plot_retransmission.stdout.log" 2>&1 || true
  fi

  # python3 "$BASE_DIR/graph/iperf_jsh.py" "$OUT_DIR" \
  #   > "$OUT_DIR/plot_iperf.stdout.log" 2>&1 || true

  if [ -f "$OUT_DIR/server_rtt.csv" ]; then
    python3 "$BASE_DIR/graph/rtt.py" "$OUT_DIR/server_rtt.csv" \
      > "$OUT_DIR/plot_app_rtt.stdout.log" 2>&1 || true
  fi
}

shutdown_handler() {
  STOP_REQUESTED=1
  echo "[INFO] Shutdown requested. Cleaning up..."

  stop_iperf_servers

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
  stop_iperf_servers || true

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

echo "[INFO] Starting multiport iperf3 one-shot server loop on ports: ${IPERF_PORTS[*]}"
if [ -n "$APP_RTT_PORT" ]; then
  echo "[INFO] App-level RTT port: $APP_RTT_PORT interval=${APP_RTT_INTERVAL_MS}ms"
fi

while [ "$STOP_REQUESTED" -eq 0 ]; do
  reset_state

  start_early_tcpdump
  start_rtt_sender

  : > "$IPERF_PIDS_FILE"
  for p in "${IPERF_PORTS[@]}"; do
    echo "[INFO] Starting iperf3 server on port $p"
    iperf3 -s -p "$p" -4 -1 -i "$IPERF_INTERVAL" --json \
      > "$TMP_ROOT/server_iperf_tmp_${p}.json" \
      2> "$TMP_ROOT/server_iperf_tmp_${p}.stderr.log" &
    echo $! >> "$IPERF_PIDS_FILE"
  done

  while read -r pid; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done < "$IPERF_PIDS_FILE"
  rm -f "$IPERF_PIDS_FILE"

  [ "$STOP_REQUESTED" -eq 1 ] && exit 0

  OUT_DIR=""
  if OUT_DIR="$(wait_for_outdir 30)"; then
    stop_tcpdump_only

    if [ -f "$TMP_ROOT/server_rtt.pid" ]; then
      rpid="$(cat "$TMP_ROOT/server_rtt.pid" 2>/dev/null || true)"
      [ -n "$rpid" ] && kill -TERM "$rpid" 2>/dev/null || true
      [ -n "$rpid" ] && wait "$rpid" 2>/dev/null || true
      rm -f "$TMP_ROOT/server_rtt.pid"
    fi

    move_early_tcpdump_to_outdir "$OUT_DIR"
    move_iperf_to_outdir "$OUT_DIR"
    move_rtt_to_outdir "$OUT_DIR"

    FIRST_JSON="$(first_existing_iperf_json "$OUT_DIR" || true)"
    if [ -n "$FIRST_JSON" ]; then
      mapfile -t INFO < <(read_iperf_info "$FIRST_JSON")
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

    echo "[INFO] Saved iperf server results to $FINAL_OUT_DIR/server_iperf_<port>.json"
    [ -f "$FINAL_OUT_DIR/server_rtt.csv" ] && echo "[INFO] Saved app-level RTT result to $FINAL_OUT_DIR/server_rtt.csv"

    stop_all_monitors
    plot_server_graphs "$FINAL_OUT_DIR" "$PROTOCOL"

    reset_state
  else
    echo "[WARN] Missing OUT_DIR for this run. Cleaning state without orphan folder."
    stop_iperf_servers || true
    stop_all_monitors || true
    reset_state
  fi
done