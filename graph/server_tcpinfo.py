#!/usr/bin/env python3
import os
import re
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <out_dir>", file=sys.stderr)
    sys.exit(1)

path = sys.argv[1]
logfile = os.path.join(path, "ss_tcpinfo.log")

if not os.path.exists(logfile):
    print(f"[WARN] Missing {logfile}", file=sys.stderr)
    sys.exit(0)

times = []
cwnds = []
rtts = []
bytes_sents = []
bytes_recvs = []
unackeds = []
delivery_rates = []

current_time = None
best_entry = None

def parse_metrics(line):
    cwnd = None
    rtt = None
    bytes_sent = 0
    bytes_received = 0
    unacked = 0
    delivery_rate = 0.0

    m = re.search(r"cwnd:(\d+)", line)
    if m:
        cwnd = int(m.group(1))

    m = re.search(r"rtt:([0-9.]+)", line)
    if m:
        rtt = float(m.group(1))

    m = re.search(r"bytes_sent:(\d+)", line)
    if m:
        bytes_sent = int(m.group(1))

    m = re.search(r"bytes_received:(\d+)", line)
    if m:
        bytes_received = int(m.group(1))

    m = re.search(r"unacked:(\d+)", line)
    if m:
        unacked = int(m.group(1))

    m = re.search(r"delivery_rate ([0-9]+)bps", line)
    if m:
        delivery_rate = float(m.group(1))

    return cwnd, rtt, bytes_sent, bytes_received, unacked, delivery_rate

def flush_best():
    if best_entry is not None:
        times.append(best_entry["time"])
        cwnds.append(best_entry["cwnd"])
        rtts.append(best_entry["rtt"])
        bytes_sents.append(best_entry["bytes_sent"])
        bytes_recvs.append(best_entry["bytes_received"])
        unackeds.append(best_entry["unacked"])
        delivery_rates.append(best_entry["delivery_rate"] / 1e6)  # Mbps

with open(logfile) as f:
    for line in f:
        line = line.strip()

        if re.match(r"^\d+\.\d+$", line):
            flush_best()
            current_time = float(line)
            best_entry = None
            continue

        if "cwnd:" in line and "rtt:" in line:
            cwnd, rtt, bytes_sent, bytes_received, unacked, delivery_rate = parse_metrics(line)
            if cwnd is None or rtt is None or current_time is None:
                continue

            score = bytes_sent + bytes_received

            if best_entry is None or score > best_entry["score"]:
                best_entry = {
                    "time": current_time,
                    "cwnd": cwnd,
                    "rtt": rtt,
                    "bytes_sent": bytes_sent,
                    "bytes_received": bytes_received,
                    "unacked": unacked,
                    "delivery_rate": delivery_rate,
                    "score": score,
                }

flush_best()

if not times:
    print("[WARN] No valid TCP info data found", file=sys.stderr)
    sys.exit(0)

t0 = times[0]
times = [t - t0 for t in times]

plt.figure()
plt.plot(times, cwnds)
plt.xlabel("Time (s)")
plt.ylabel("cwnd")
plt.title("Server cwnd over Time")
plt.grid()
plt.savefig(os.path.join(path, "server_cwnd.png"), dpi=150, bbox_inches="tight")
plt.close()

plt.figure()
plt.plot(times, rtts)
plt.xlabel("Time (s)")
plt.ylabel("RTT (ms)")
plt.title("Server TCP RTT over Time")
plt.grid()
plt.savefig(os.path.join(path, "server_tcp_rtt.png"), dpi=150, bbox_inches="tight")
plt.close()

plt.figure()
plt.plot(times, unackeds)
plt.xlabel("Time (s)")
plt.ylabel("unacked")
plt.title("Server Unacked Packets over Time")
plt.grid()
plt.savefig(os.path.join(path, "server_unacked.png"), dpi=150, bbox_inches="tight")
plt.close()

plt.figure()
plt.plot(times, delivery_rates)
plt.xlabel("Time (s)")
plt.ylabel("Delivery Rate (Mbps)")
plt.title("Server Delivery Rate over Time")
plt.grid()
plt.savefig(os.path.join(path, "server_delivery_rate.png"), dpi=150, bbox_inches="tight")
plt.close()