#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$1"
CLIENT_IP="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

mkdir -p "$OUT_DIR"
mkdir -p "$TMP_ROOT"

# tcpdump: 한 run 동안 server port 관련 패킷 전체 캡처
nohup sudo tcpdump -i "$SERVER_IFACE" -s "$TCPDUMP_SNAPLEN" \
  -w "$OUT_DIR/server_tcpdump.pcap" \
  "port $SERVER_PORT" \
  > "$OUT_DIR/tcpdump_stdout.log" 2>&1 &
echo $! > "$TMP_ROOT/server_tcpdump.pid"

# ss / tcp_info
nohup bash -c "
while true; do
  date +%s.%N
  ss -tin sport = :$SERVER_PORT || true
  sleep $SS_INTERVAL
done
" > "$OUT_DIR/ss_tcpinfo.log" 2>&1 &
echo $! > "$TMP_ROOT/server_ss.pid"

# ss parser
nohup bash "$BASE_DIR/bin/server_parse_ss.sh" "$OUT_DIR" \
  > "$OUT_DIR/ss_parse_stdout.log" 2>&1 &
echo $! > "$TMP_ROOT/server_ss_parse.pid"

# interface stats
nohup bash -c "
while true; do
  date +%s.%N
  ip -s link show dev $SERVER_IFACE || true
  tc -s qdisc show dev $SERVER_IFACE || true
  sleep $IFACE_INTERVAL
done
" > "$OUT_DIR/iface_stats.log" 2>&1 &
echo $! > "$TMP_ROOT/server_iface.pid"