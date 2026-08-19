#!/usr/bin/env python3

import os
import re
import sys

import matplotlib
matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib import ticker


if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <out_dir>", file=sys.stderr)
    sys.exit(1)

path = sys.argv[1]
logfile = os.path.join(path, "ss_rtt.log")

if not os.path.exists(logfile):
    print(f"[WARN] Missing {logfile}", file=sys.stderr)
    sys.exit(0)


# ============================================================
# 4-tuple별 connection 데이터
#
# connections[
#   (local_ip, local_port, remote_ip, remote_port)
# ] = {...}
# ============================================================

connections = {}


def get_connection(conn_id):
    if conn_id not in connections:
        connections[conn_id] = {
            "local_ip": conn_id[0],
            "local_port": conn_id[1],
            "remote_ip": conn_id[2],
            "remote_port": conn_id[3],

            "times": [],
            "cwnds": [],
            "rtts": [],
            "rttvars": [],
            "bytes_sents": [],
            "bytes_recvs": [],
            "unackeds": [],
            "delivery_rates": [],
            "retrans": [],
        }

    return connections[conn_id]


def parse_line(line):
    # timestamp
    m = re.match(r"^([0-9.]+)", line)
    if not m:
        return None

    timestamp = float(m.group(1))

    # RTT
    m = re.search(r"\brtt_ms=([0-9.]+)", line)
    rtt = float(m.group(1)) if m else None

    # RTT variation
    m = re.search(r"\brttvar_ms=([0-9.]+)", line)
    rttvar = float(m.group(1)) if m else None

    # cwnd
    m = re.search(r"\bcwnd=(\d+)", line)
    cwnd = int(m.group(1)) if m else None

    # bytes_sent
    m = re.search(r"\bbytes_sent=(\d+)", line)
    bytes_sent = int(m.group(1)) if m else 0

    # bytes_received
    m = re.search(r"\bbytes_received=(\d+)", line)
    bytes_received = int(m.group(1)) if m else 0

    # unacked
    m = re.search(r"\bunacked=(\d+)", line)
    unacked = int(m.group(1)) if m else 0

    # delivery rate
    m = re.search(r"\bdelivery_rate_bps=(\d+)", line)
    delivery_rate = float(m.group(1)) if m else 0.0

    # retrans
    m = re.search(r"\bretrans=([^\s]*)", line)
    retrans = m.group(1) if m else ""

    # Connection:
    #
    # conn="ESTAB ... 172.31.22.8:20075 150.228.147.185:43774"
    #
    m = re.search(
    r'conn="\s*'
    r'.*?\s+'
    r'([^"\s]+):(\d+)\s+'
    r'([^"\s]+):(\d+)'
    r'\s*"',
    line
)

    if not m:
        return None

    local_ip = m.group(1)
    local_port = int(m.group(2))
    remote_ip = m.group(3)
    remote_port = int(m.group(4))

    conn_id = (
        local_ip,
        local_port,
        remote_ip,
        remote_port,
    )

    return {
        "timestamp": timestamp,
        "conn_id": conn_id,
        "rtt": rtt,
        "rttvar": rttvar,
        "cwnd": cwnd,
        "bytes_sent": bytes_sent,
        "bytes_received": bytes_received,
        "unacked": unacked,
        "delivery_rate": delivery_rate,
        "retrans": retrans,
    }


# ============================================================
# 로그 읽기
# ============================================================

with open(logfile) as f:
    for line in f:
        line = line.strip()

        if not line:
            continue

        entry = parse_line(line)

        if entry is None:
            continue

        if entry["cwnd"] is None or entry["rtt"] is None:
            continue

        conn = get_connection(entry["conn_id"])

        conn["times"].append(entry["timestamp"])
        conn["cwnds"].append(entry["cwnd"])
        conn["rtts"].append(entry["rtt"])
        conn["rttvars"].append(entry["rttvar"])
        conn["bytes_sents"].append(entry["bytes_sent"])
        conn["bytes_recvs"].append(entry["bytes_received"])
        conn["unackeds"].append(entry["unacked"])

        # bps -> Mbps
        conn["delivery_rates"].append(
            entry["delivery_rate"] / 1e6
        )

        conn["retrans"].append(entry["retrans"])


if not connections:
    print("[WARN] No TCP connections found", file=sys.stderr)
    sys.exit(0)


# ============================================================
# Connection별 실제 전송량 계산
#
# 누적 counter의 마지막 값 자체를 비교하는 것보다
# max - min 변화량을 사용하는 것이 안전함.
# ============================================================

for conn in connections.values():

    if conn["bytes_sents"]:
        sent_delta = (
            max(conn["bytes_sents"])
            - min(conn["bytes_sents"])
        )
    else:
        sent_delta = 0

    if conn["bytes_recvs"]:
        recv_delta = (
            max(conn["bytes_recvs"])
            - min(conn["bytes_recvs"])
        )
    else:
        recv_delta = 0

    conn["traffic_bytes"] = sent_delta + recv_delta


# ============================================================
# 같은 server port에서 가장 traffic이 큰 connection 선택
#
# 즉:
#
# port 20075
#   control connection
#   data connection    <-- 선택
#
# port 20077
#   control connection
#   data connection    <-- 선택
# ============================================================

data_flows = {}

for conn_id, conn in connections.items():

    server_port = conn["local_port"]

    current = data_flows.get(server_port)

    if (
        current is None
        or conn["traffic_bytes"] > current["traffic_bytes"]
    ):
        data_flows[server_port] = conn


if not data_flows:
    print("[WARN] No data flows found", file=sys.stderr)
    sys.exit(0)


# ============================================================
# 어떤 connection을 선택했는지 출력
# ============================================================

print("[INFO] Detected connections:")

for conn_id, conn in sorted(
    connections.items(),
    key=lambda x: (x[1]["local_port"], x[1]["remote_port"])
):
    print(
        f"  {conn['local_ip']}:{conn['local_port']} "
        f"<-> "
        f"{conn['remote_ip']}:{conn['remote_port']} "
        f"traffic={conn['traffic_bytes']} bytes"
    )


print()
print("[INFO] Selected iperf DATA flows:")

for port in sorted(data_flows):

    conn = data_flows[port]

    print(
        f"  Flow {port}: "
        f"{conn['local_ip']}:{conn['local_port']} "
        f"<-> "
        f"{conn['remote_ip']}:{conn['remote_port']} "
        f"traffic={conn['traffic_bytes']} bytes "
        f"samples={len(conn['times'])}"
    )


# ============================================================
# 공통 시간축
#
# flow별 첫 sample을 각각 0으로 만들면 안 됨.
# 모든 data flow 중 가장 이른 timestamp를 사용.
# ============================================================

t0 = min(
    min(conn["times"])
    for conn in data_flows.values()
    if conn["times"]
)

for conn in data_flows.values():
    conn["rel_times"] = [
        t - t0
        for t in conn["times"]
    ]


# ============================================================
# CWND
# ============================================================

plt.figure(figsize=(12, 4))

for port in sorted(data_flows):

    conn = data_flows[port]

    plt.plot(
        conn["rel_times"],
        conn["cwnds"],
        linewidth=1.2,
        label=f"Flow {port}",
        alpha=0.7
    )


ax = plt.gca()

ax.xaxis.set_major_locator(
    ticker.MultipleLocator(10)
)

ax.xaxis.set_minor_locator(
    ticker.MultipleLocator(1)
)

plt.xlabel("Time (s)")
plt.ylabel("cwnd (segments)")
plt.title("Server cwnd over Time")

plt.legend()
plt.grid()

plt.savefig(
    os.path.join(path, "server_cwnd.png"),
    dpi=150,
    bbox_inches="tight",
)

plt.close()


# ============================================================
# RTT
# ============================================================

plt.figure(figsize=(12, 4))

for port in sorted(data_flows):

    conn = data_flows[port]

    plt.plot(
        conn["rel_times"],
        conn["rtts"],
        linewidth=1.2,
        label=f"Flow {port}",
        alpha=0.7
    )


ax = plt.gca()

ax.xaxis.set_major_locator(
    ticker.MultipleLocator(10)
)

ax.xaxis.set_minor_locator(
    ticker.MultipleLocator(1)
)

ax.set_ylim(
    bottom=0,
    top=250,
)

plt.xlabel("Time (s)")
plt.ylabel("RTT (ms)")
plt.title("Server TCP RTT over Time")

plt.legend()
plt.grid()

plt.savefig(
    os.path.join(path, "server_tcp_rtt.png"),
    dpi=150,
    bbox_inches="tight",
)

plt.close()

# ============================================================
# UNACKED
# ============================================================

plt.figure(figsize=(12, 4))

for port in sorted(data_flows):

    conn = data_flows[port]

    plt.plot(
        conn["rel_times"],
        conn["unackeds"],
        linewidth=1.2,
        label=f"Flow {port}",
        alpha=0.7,
    )

ax = plt.gca()

ax.xaxis.set_major_locator(
    ticker.MultipleLocator(10)
)

ax.xaxis.set_minor_locator(
    ticker.MultipleLocator(1)
)

plt.xlabel("Time (s)")
plt.ylabel("Unacked (segments)")
plt.title("Server TCP Unacked Segments over Time")

plt.legend()
plt.grid()

plt.savefig(
    os.path.join(path, "server_unacked.png"),
    dpi=150,
    bbox_inches="tight",
)

plt.close()