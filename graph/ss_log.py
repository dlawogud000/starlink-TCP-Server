#!/usr/bin/env python3

import os
import re
import sys
from collections import defaultdict

ALLOWED_PORTS = {20075, 20076, 20077}

if len(sys.argv) < 2:
    print(
        f"Usage: {sys.argv[0]} <experiment_dir> [output_filename]",
        file=sys.stderr,
    )
    sys.exit(1)

EXP_DIR = sys.argv[1]

INPUT_FILE = os.path.join(
    EXP_DIR,
    "ss_tcpinfo.log"
)

OUTPUT_NAME = (
    sys.argv[2]
    if len(sys.argv) >= 3
    else "ss_rtt_data.log"
)

OUTPUT_FILE = os.path.join(
    EXP_DIR,
    OUTPUT_NAME
)

if not os.path.exists(INPUT_FILE):
    print(f"[ERROR] Missing {INPUT_FILE}", file=sys.stderr)
    sys.exit(1)


# ============================================================
# Regex
# ============================================================

TIMESTAMP_RE = re.compile(
    r"^[0-9]+\.[0-9]+$"
)

# Example:
#
# ESTAB 0 72400 172.31.22.8:20075 150.228.147.185:43774
#
CONN_RE = re.compile(
    r"^ESTAB\s+"
    r"(\d+)\s+"          # Recv-Q
    r"(\d+)\s+"          # Send-Q
    r"(\S+):(\d+)\s+"    # local IP:port
    r"(\S+):(\d+)\s*$"   # remote IP:port
)

RTT_RE = re.compile(
    r"(?:^|\s)rtt:([0-9.]+)/([0-9.]+)"
)

CWND_RE = re.compile(
    r"(?:^|\s)cwnd:(\d+)"
)

BYTES_SENT_RE = re.compile(
    r"(?:^|\s)bytes_sent:(\d+)"
)

BYTES_RECEIVED_RE = re.compile(
    r"(?:^|\s)bytes_received:(\d+)"
)

UNACKED_RE = re.compile(
    r"(?:^|\s)unacked:(\d+)"
)

RETRANS_RE = re.compile(
    r"(?:^|\s)retrans:([^\s]+)"
)

DELIVERY_RATE_RE = re.compile(
    r"(?:^|\s)delivery_rate\s+(\d+)bps"
)


# ============================================================
# Connection parsing
# ============================================================

def parse_connection(line):
    m = CONN_RE.match(line.strip())

    if not m:
        return None

    recvq = int(m.group(1))
    sendq = int(m.group(2))

    local_ip = m.group(3)
    local_port = int(m.group(4))

    remote_ip = m.group(5)
    remote_port = int(m.group(6))

    conn_id = (
        local_ip,
        local_port,
        remote_ip,
        remote_port,
    )

    return {
        "conn_id": conn_id,
        "recvq": recvq,
        "sendq": sendq,
        "conn_line": line.strip(),
    }


def parse_tcpinfo(line):

    m = RTT_RE.search(line)

    if m:
        rtt_ms = float(m.group(1))
        rttvar_ms = float(m.group(2))
    else:
        rtt_ms = None
        rttvar_ms = None

    m = CWND_RE.search(line)
    cwnd = int(m.group(1)) if m else None

    m = BYTES_SENT_RE.search(line)
    bytes_sent = int(m.group(1)) if m else 0

    m = BYTES_RECEIVED_RE.search(line)
    bytes_received = int(m.group(1)) if m else 0

    m = UNACKED_RE.search(line)
    unacked = int(m.group(1)) if m else 0

    m = RETRANS_RE.search(line)
    retrans = m.group(1) if m else ""

    m = DELIVERY_RATE_RE.search(line)
    delivery_rate_bps = int(m.group(1)) if m else 0

    return {
        "rtt_ms": rtt_ms,
        "rttvar_ms": rttvar_ms,
        "cwnd": cwnd,
        "bytes_sent": bytes_sent,
        "bytes_received": bytes_received,
        "unacked": unacked,
        "retrans": retrans,
        "delivery_rate_bps": delivery_rate_bps,
    }


# ============================================================
# PASS 1
#
# 4-tuple별 traffic 양 계산.
# 같은 server port에서 traffic이 가장 큰 connection을
# iperf DATA connection으로 선택한다.
# ============================================================

stats = defaultdict(
    lambda: {
        "sent_min": None,
        "sent_max": None,
        "recv_min": None,
        "recv_max": None,
        "samples": 0,
    }
)

current_conn = None


with open(INPUT_FILE, "r") as f:

    for raw_line in f:

        stripped = raw_line.strip()

        conn_info = parse_connection(stripped)

        if conn_info is not None:
            current_conn = conn_info["conn_id"]
            continue

        if current_conn is None:
            continue

        info = parse_tcpinfo(stripped)

        # tcp_info line이 아니면 다음 줄을 계속 확인
        if (
            info["rtt_ms"] is None
            and info["cwnd"] is None
            and info["bytes_sent"] == 0
            and info["bytes_received"] == 0
        ):
            continue

        st = stats[current_conn]

        sent = info["bytes_sent"]
        recv = info["bytes_received"]

        if st["sent_min"] is None:
            st["sent_min"] = sent
            st["sent_max"] = sent
        else:
            st["sent_min"] = min(
                st["sent_min"],
                sent
            )
            st["sent_max"] = max(
                st["sent_max"],
                sent
            )

        if st["recv_min"] is None:
            st["recv_min"] = recv
            st["recv_max"] = recv
        else:
            st["recv_min"] = min(
                st["recv_min"],
                recv
            )
            st["recv_max"] = max(
                st["recv_max"],
                recv
            )

        st["samples"] += 1

        current_conn = None


# ============================================================
# Connection별 전체 traffic 계산
# ============================================================

for conn, st in stats.items():

    sent_delta = 0
    recv_delta = 0

    if (
        st["sent_min"] is not None
        and st["sent_max"] is not None
    ):
        sent_delta = (
            st["sent_max"]
            - st["sent_min"]
        )

    if (
        st["recv_min"] is not None
        and st["recv_max"] is not None
    ):
        recv_delta = (
            st["recv_max"]
            - st["recv_min"]
        )

    st["traffic_bytes"] = (
        sent_delta
        + recv_delta
    )


# ============================================================
# 같은 local/server port 중 가장 큰 connection 선택
# ============================================================

data_connections = {}


for conn, st in stats.items():

    local_ip, local_port, remote_ip, remote_port = conn

    if local_port not in ALLOWED_PORTS:
        continue

    current_conn = data_connections.get(local_port)

    if current_conn is None:
        data_connections[local_port] = conn

    elif (
        st["traffic_bytes"]
        > stats[current_conn]["traffic_bytes"]
    ):
        data_connections[local_port] = conn


selected_set = set(
    data_connections.values()
)


# ============================================================
# 선택 결과 출력
# ============================================================

print("[INFO] Detected connections:")

for conn in sorted(
    stats,
    key=lambda x: (
        x[1],
        x[3],
    )
):
    st = stats[conn]

    print(
        f"  {conn[0]}:{conn[1]} "
        f"<-> "
        f"{conn[2]}:{conn[3]} "
        f"traffic={st['traffic_bytes']} bytes "
        f"samples={st['samples']}"
    )


print()
print("[INFO] Selected DATA connections:")

for port in sorted(data_connections):
    conn = data_connections[port]
    st = stats[conn]

    print(
        f"  Flow {port}: "
        f"{conn[0]}:{conn[1]} "
        f"<-> "
        f"{conn[2]}:{conn[3]} "
        f"traffic={st['traffic_bytes']} bytes "
        f"samples={st['samples']}"
    )


# ============================================================
# PASS 2
#
# 선택된 DATA connection만 읽어서
# 기존 ss_rtt.log 형식으로 출력
# ============================================================

current_timestamp = None
current_conn_info = None


with open(INPUT_FILE, "r") as src, \
     open(OUTPUT_FILE, "w") as dst:

    for raw_line in src:

        stripped = raw_line.strip()

        # ----------------------------------------
        # Timestamp
        # ----------------------------------------

        if TIMESTAMP_RE.match(stripped):
            current_timestamp = stripped
            current_conn_info = None
            continue

        # ----------------------------------------
        # Connection
        # ----------------------------------------

        conn_info = parse_connection(stripped)

        if conn_info is not None:
            current_conn_info = conn_info
            continue

        # ----------------------------------------
        # TCP info
        # ----------------------------------------

        if current_conn_info is None:
            continue

        conn_id = current_conn_info["conn_id"]

        # control connection이면 무시
        if conn_id[1] not in ALLOWED_PORTS:
            current_conn_info = None
            continue

        if conn_id not in selected_set:
            current_conn_info = None
            continue

        info = parse_tcpinfo(stripped)

        # 정상적인 tcp_info line인지 확인
        if info["rtt_ms"] is None:
            continue

        if current_timestamp is None:
            continue

        rtt_ms = info["rtt_ms"]
        rttvar_ms = (
            info["rttvar_ms"]
            if info["rttvar_ms"] is not None
            else 0
        )

        cwnd = (
            info["cwnd"]
            if info["cwnd"] is not None
            else 0
        )

        bytes_sent = info["bytes_sent"]
        bytes_received = info["bytes_received"]
        unacked = info["unacked"]
        delivery_rate = info["delivery_rate_bps"]
        retrans = info["retrans"]

        recvq = current_conn_info["recvq"]
        sendq = current_conn_info["sendq"]

        conn_line = current_conn_info["conn_line"]

        # 기존 ss_rtt.log와 동일한 한 줄 형식
        dst.write(
            f"{current_timestamp} "
            f"rtt_ms={rtt_ms} "
            f"rttvar_ms={rttvar_ms} "
            f"cwnd={cwnd} "
            f"bytes_sent={bytes_sent} "
            f"bytes_received={bytes_received} "
            f"unacked={unacked} "
            f"delivery_rate_bps={delivery_rate} "
            f"retrans={retrans} "
            f"recvq={recvq} "
            f"sendq={sendq} "
            f'conn="{conn_line}"\n'
        )

        current_conn_info = None


print()
print(
    "[INFO] DATA-only ss_rtt log written to:\n"
    f"  {OUTPUT_FILE}"
)