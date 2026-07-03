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
    filter="$filter or port $APP_RTT_PORT"
  fi

  if [ -n "${CLIENT_IP:-}" ] && [ "$CLIENT_IP" != "-" ] && [ "$CLIENT_IP" != "unknown" ]; then
    echo "host $CLIENT_IP and ( $filter )"
  else
    echo "$filter"
  fi
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
  if [ -n "${APP_RTT_PORT:-}" ]; then
    filter="$filter or sport = :$APP_RTT_PORT"
  fi
  echo "$filter"
}

if [ -f "$TMP_ROOT/server_tcpdump.pid" ] && kill -0 "$(cat "$TMP_ROOT/server_tcpdump.pid" 2>/dev/null)" 2>/dev/null; then
  echo "[INFO] tcpdump already started early by run_server.sh" > "$OUT_DIR/tcpdump_start_info.log"
else
  TCPDUMP_FILTER="$(build_port_filter)"
  sudo setsid tcpdump -i "$SERVER_IFACE" -s "$TCPDUMP_SNAPLEN" \
    -w "$OUT_DIR/server_tcpdump.pcap" \
    "$TCPDUMP_FILTER" \
    > "$OUT_DIR/tcpdump_stdout.log" 2>&1 &
  echo $! > "$TMP_ROOT/server_tcpdump.pid"
fi

SS_FILTER="$(build_ss_filter)"

setsid bash -c "
while true; do
  date +%s.%N
  ss -tin '$SS_FILTER' || true
  sleep $SS_INTERVAL
done
" > "$OUT_DIR/ss_tcpinfo.log" 2>&1 &
echo $! > "$TMP_ROOT/server_ss.pid"


setsid bash "$BASE_DIR/bin/server_parse_ss.sh" "$OUT_DIR" \
  > "$OUT_DIR/ss_parse_stdout.log" 2>&1 &
echo $! > "$TMP_ROOT/server_ss_parse.pid"

setsid bash -c "
while true; do
  date +%s.%N
  ip -s link show dev $SERVER_IFACE || true
  tc -s qdisc show dev $SERVER_IFACE || true
  sleep $IFACE_INTERVAL
done
" > "$OUT_DIR/iface_stats.log" 2>&1 &
echo $! > "$TMP_ROOT/server_iface.pid"