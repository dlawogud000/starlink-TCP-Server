#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/experiment.conf"

TCPINFO_LOG="$OUT_DIR/ss_tcpinfo.log"
RTT_LOG="$OUT_DIR/ss_rtt.log"

while [ ! -f "$TCPINFO_LOG" ]; do
    sleep 0.1
done

# 새 실험이라면 기존 파싱 결과를 비워두는 것이 안전
: > "$RTT_LOG"

tail -n 0 -F "$TCPINFO_LOG" 2>/dev/null | awk '

BEGIN {
    ts = ""

    conn_state = ""
    conn_sendq = ""
    conn_recvq = ""
    conn_line = ""

    entries_in_block = 0
}

# ------------------------------------------------------------
# Timestamp
#
# ss_tcpinfo.log:
#
# 1786263391.294613616
# State ...
# ESTAB ...
#      cubic ... rtt:... cwnd:...
# ESTAB ...
#      cubic ... rtt:... cwnd:...
#
# 다음 timestamp가 나오기 전까지 모든 connection은
# 동일 timestamp의 sample이다.
# ------------------------------------------------------------

/^[0-9]+\.[0-9]+$/ {
    ts = $0

    conn_state = ""
    conn_sendq = ""
    conn_recvq = ""
    conn_line = ""

    entries_in_block = 0

    next
}

# ss header 무시
/^State[[:space:]]/ {
    next
}

# ------------------------------------------------------------
# Connection line
#
# 예:
#
# ESTAB 0 72400 172.31.22.8:20075 150.228.147.185:43774
#
# 이 줄 바로 다음 tcp_info 줄과 연결한다.
# ------------------------------------------------------------

/^[A-Z0-9-]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {

    conn_state = $1
    conn_recvq = $2 + 0
    conn_sendq = $3 + 0
    conn_line = $0

    next
}

# ------------------------------------------------------------
# tcp_info line
#
# 중요:
# 이전 코드와 달리 "best connection"을 선택하지 않는다.
# ESTAB connection이면 발견되는 모든 connection을 출력한다.
# ------------------------------------------------------------

conn_state == "ESTAB" && /(^|[[:space:]])rtt:[0-9.]+\/[0-9.]+/ {

    line = $0

    rtt = ""
    rttvar = ""
    cwnd = ""
    bytes_sent = ""
    bytes_received = ""
    unacked = ""
    retrans = ""
    delivery_rate = ""

    # RTT / RTTVAR
    if (match(line, /(^|[[:space:]])rtt:[0-9.]+\/[0-9.]+/)) {
        tmp = substr(line, RSTART, RLENGTH)

        sub(/^[[:space:]]*rtt:/, "", tmp)
        sub(/^[[:space:]]+/, "", tmp)

        split(tmp, a, "/")

        rtt = a[1]
        rttvar = a[2]
    }

    # CWND
    if (match(line, /(^|[[:space:]])cwnd:[0-9]+/)) {
        tmp = substr(line, RSTART, RLENGTH)

        sub(/^[[:space:]]*cwnd:/, "", tmp)
        sub(/^[[:space:]]+/, "", tmp)

        cwnd = tmp
    }

    # bytes_sent
    if (match(line, /(^|[[:space:]])bytes_sent:[0-9]+/)) {
        tmp = substr(line, RSTART, RLENGTH)

        sub(/^[[:space:]]*bytes_sent:/, "", tmp)
        sub(/^[[:space:]]+/, "", tmp)

        bytes_sent = tmp
    }

    # bytes_received
    if (match(line, /(^|[[:space:]])bytes_received:[0-9]+/)) {
        tmp = substr(line, RSTART, RLENGTH)

        sub(/^[[:space:]]*bytes_received:/, "", tmp)
        sub(/^[[:space:]]+/, "", tmp)

        bytes_received = tmp
    }

    # unacked
    if (match(line, /(^|[[:space:]])unacked:[0-9]+/)) {
        tmp = substr(line, RSTART, RLENGTH)

        sub(/^[[:space:]]*unacked:/, "", tmp)
        sub(/^[[:space:]]+/, "", tmp)

        unacked = tmp
    }

    # retrans
    if (match(line, /(^|[[:space:]])retrans:[^[:space:]]+/)) {
        tmp = substr(line, RSTART, RLENGTH)

        sub(/^[[:space:]]*retrans:/, "", tmp)
        sub(/^[[:space:]]+/, "", tmp)

        retrans = tmp
    }

    # delivery_rate
    if (match(line, /(^|[[:space:]])delivery_rate [0-9]+bps/)) {
        tmp = substr(line, RSTART, RLENGTH)

        sub(/^[[:space:]]*delivery_rate /, "", tmp)
        sub(/bps$/, "", tmp)

        delivery_rate = tmp
    }

    # --------------------------------------------------------
    # 핵심:
    # 발견된 모든 ESTAB connection을 즉시 출력
    # --------------------------------------------------------

    if (ts != "") {
        print ts, \
              "rtt_ms=" rtt, \
              "rttvar_ms=" rttvar, \
              "cwnd=" cwnd, \
              "bytes_sent=" bytes_sent, \
              "bytes_received=" bytes_received, \
              "unacked=" unacked, \
              "delivery_rate_bps=" delivery_rate, \
              "retrans=" retrans, \
              "recvq=" conn_recvq, \
              "sendq=" conn_sendq, \
              "conn=\"" conn_line "\""

        fflush()

        entries_in_block++
    }

    # 다음 connection을 위해 초기화
    conn_state = ""
    conn_sendq = ""
    conn_recvq = ""
    conn_line = ""

    next
}
' >> "$RTT_LOG"