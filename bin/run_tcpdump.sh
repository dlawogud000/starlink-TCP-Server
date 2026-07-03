#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$1"
CLIENT_IP="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

mkdir -p "$OUT_DIR"
mkdir -p "$TMP_ROOT"

normalize_ports() {
  local s="${1:-}"
  s="${s//,/ }"
  for p in $s; do
    [[ -n "$p" ]] && echo "$p"
  done
}

build_port_filter() {
  local filter=""
  local p

  for p in $(normalize_ports "${SERVER_PORTS:-$SERVER_PORT}"); do
    if [ -z "$filter" ]; then
      filter="port $p"
    else
      filter="$filter or port $p"
    fi
  done

  if [ -n "${APP_RTT_PORT:-}" ]; then
    if [ -z "$filter" ]; then
      filter="port $APP_RTT_PORT"
    else
      filter="$filter or port $APP_RTT_PORT"
    fi
  fi

  echo "$filter"
}

build_tcpdump_filter() {
  local port_filter
  port_filter="$(build_port_filter)"

  if [ -n "${CLIENT_IP:-}" ] && [ "$CLIENT_IP" != "-" ] && [ "$CLIENT_IP" != "unknown" ]; then
    echo "host $CLIENT_IP and ( $port_filter )"
  else
    echo "$port_filter"
  fi
}

TCPDUMP_FILTER="$(build_tcpdump_filter)"

echo "[INFO] early tcpdump filter=$TCPDUMP_FILTER" | tee "$OUT_DIR/early_tcpdump_info.log"

sudo setsid tcpdump -i "$SERVER_IFACE" \
  -s "$TCPDUMP_SNAPLEN" -U -B 4096 \
  -w "$OUT_DIR/server_tcpdump.pcap" \
  "$TCPDUMP_FILTER" \
  > "$OUT_DIR/tcpdump_stdout.log" 2>&1 &

echo $! > "$TMP_ROOT/server_tcpdump.pid"

sleep "${TCPDUMP_WARMUP_SEC:-1}"