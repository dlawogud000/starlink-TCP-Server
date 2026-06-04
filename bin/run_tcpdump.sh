#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$1"
CLIENT_IP="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

mkdir -p "$OUT_DIR"
mkdir -p "$TMP_ROOT"

SERVER_PORTS="${SERVER_PORTS:-$SERVER_PORT}"

build_tcpdump_filter() {
  if [ -n "${CLIENT_IP:-}" ] && [ "$CLIENT_IP" != "-" ] && [ "$CLIENT_IP" != "unknown" ]; then
    echo "host $CLIENT_IP"
    return
  fi

  local filter=""
  for p in $SERVER_PORTS; do
    if [ -z "$filter" ]; then
      filter="port $p"
    else
      filter="$filter or port $p"
    fi
  done
  echo "$filter"
}

TCPDUMP_FILTER="$(build_tcpdump_filter)"

echo "[INFO] early tcpdump filter=$TCPDUMP_FILTER" | tee "$OUT_DIR/early_tcpdump_info.log"

sudo setsid tcpdump -i "$SERVER_IFACE" \
  -s 0 -U -B 4096 \
  -w "$OUT_DIR/server_tcpdump.pcap" \
  "$TCPDUMP_FILTER" \
  > "$OUT_DIR/tcpdump_stdout.log" 2>&1 &

echo $! > "$TMP_ROOT/server_tcpdump.pid"

# Give tcpdump time to attach interface and install BPF filter before iperf starts.
sleep "${TCPDUMP_WARMUP_SEC:-1}"