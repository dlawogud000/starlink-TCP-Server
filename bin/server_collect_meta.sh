#!/usr/bin/env bash
set -euo pipefail

PROTOCOL="$1"          # tcp|udp|unknown
DIRECTION="$2"         # uplink|downlink|unknown
RUN_ID="$3"            # auto-detected id
OUT_DIR="$4"
CLIENT_IP="$5"
CLIENT_PORT="$6"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

cat > "$OUT_DIR/meta.txt" <<EOF
timestamp=$(date --iso-8601=seconds)
protocol=$PROTOCOL
direction=$DIRECTION
run_id=$RUN_ID
server_ip=$SERVER_IP
server_port=$SERVER_PORT
client_ip=$CLIENT_IP
client_port=$CLIENT_PORT
server_iface=$SERVER_IFACE
duration=$DURATION
kernel=$(uname -a)
host=$(hostname)
tcp_cc_current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
tcp_available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
EOF