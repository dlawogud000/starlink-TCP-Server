#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$1"
CLIENT_IP="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

mkdir -p "$OUT_DIR"
mkdir -p "$TMP_ROOT"

# tcpdump is started early by run_server.sh before iperf3 accepts SYN.
# If it is already running, do not start a second tcpdump and do not overwrite
# the early tcpdump pid. This preserves the SYN-containing pcap in TMP_ROOT
# until run_server.sh moves it into OUT_DIR.
if [ -f "$TMP_ROOT/server_tcpdump.pid" ] && kill -0 "$(cat "$TMP_ROOT/server_tcpdump.pid" 2>/dev/null)" 2>/dev/null; then
  echo "[INFO] tcpdump already started early by run_server.sh" > "$OUT_DIR/tcpdump_start_info.log"
else
  sudo setsid tcpdump -i "$SERVER_IFACE" -s "$TCPDUMP_SNAPLEN" \
    -w "$OUT_DIR/server_tcpdump.pcap" \
    "port $SERVER_PORT" \
    > "$OUT_DIR/tcpdump_stdout.log" 2>&1 &
  echo $! > "$TMP_ROOT/server_tcpdump.pid"
fi

# ss / tcp_info
setsid bash -c "
while true; do
  date +%s.%N
  ss -tin sport = :$SERVER_PORT || true
  sleep $SS_INTERVAL
done
" > "$OUT_DIR/ss_tcpinfo.log" 2>&1 &
echo $! > "$TMP_ROOT/server_ss.pid"

# ss parser
setsid bash "$BASE_DIR/bin/server_parse_ss.sh" "$OUT_DIR" \
  > "$OUT_DIR/ss_parse_stdout.log" 2>&1 &
echo $! > "$TMP_ROOT/server_ss_parse.pid"

# interface stats
setsid bash -c "
while true; do
  date +%s.%N
  ip -s link show dev $SERVER_IFACE || true
  tc -s qdisc show dev $SERVER_IFACE || true
  sleep $IFACE_INTERVAL
done
" > "$OUT_DIR/iface_stats.log" 2>&1 &
echo $! > "$TMP_ROOT/server_iface.pid"