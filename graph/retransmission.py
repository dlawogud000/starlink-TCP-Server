#!/usr/bin/env python3
import re
import argparse
import pandas as pd
import matplotlib.pyplot as plt
import os
import sys
import matplotlib.ticker as ticker


def parse_ss_retrans(log_path):
    rows = []
    current_ts = None
    current_conn = None

    ts_re = re.compile(r"^\d+\.\d+$")
    est_re = re.compile(
        r"ESTAB\s+\S+\s+\S+\s+(\S+:\d+)\s+(\S+:\d+)"
    )
    retrans_re = re.compile(r"\bretrans:(\d+)/(\d+)")

    with open(log_path, "r", errors="ignore") as f:
        for line in f:
            line = line.strip()

            if ts_re.match(line):
                current_ts = float(line)
                current_conn = None
                continue

            m = est_re.search(line)
            if m:
                local = m.group(1)
                peer = m.group(2)
                current_conn = f"{local} -> {peer}"
                continue

            m = retrans_re.search(line)
            if m and current_ts is not None and current_conn is not None:
                retrans_now = int(m.group(1))
                retrans_total = int(m.group(2))

                rows.append({
                    "time": current_ts,
                    "conn": current_conn,
                    "retrans_now": retrans_now,
                    "retrans_total": retrans_total,
                })

    df = pd.DataFrame(rows)
    if df.empty:
        raise RuntimeError("No retransmission data found.")

    t0 = df["time"].min()
    df["time_s"] = df["time"] - t0

    df = df.sort_values(["conn", "time_s"])
    df["retrans_delta"] = df.groupby("conn")["retrans_total"].diff().fillna(0)
    df.loc[df["retrans_delta"] < 0, "retrans_delta"] = 0

    return df


def plot_retrans(df, out_prefix, path="."):
    plt.figure(figsize=(12, 4))

    for conn, g in df.groupby("conn"):
        plt.plot(g["time_s"], g["retrans_total"],
                linewidth=1,
                label=conn)

    ax = plt.gca()

    ax.xaxis.set_major_locator(ticker.MultipleLocator(10))
    ax.xaxis.set_minor_locator(ticker.MultipleLocator(1))

    plt.xlabel("Time (s)")
    plt.ylabel("Cumulative Retransmissions")
    plt.title("TCP Retransmissions over Time")

    plt.grid(True, which="major", alpha=0.5)
    plt.grid(True, which="minor", alpha=0.2)

    plt.legend(fontsize=8)

    plt.savefig(
        os.path.join(path, "retrans_cumulative.png"),
        dpi=150,
        bbox_inches="tight"
    )
    plt.close()


    plt.figure(figsize=(12, 5))

    for conn, g in df.groupby("conn"):
        plt.plot(g["time_s"], g["retrans_delta"],
                linewidth=1,
                label=conn)

    ax = plt.gca()

    ax.xaxis.set_major_locator(ticker.MultipleLocator(10))
    ax.xaxis.set_minor_locator(ticker.MultipleLocator(1))

    plt.xlabel("Time (s)")
    plt.ylabel("Retransmitted segments per sample")
    plt.title("TCP Retransmission Increase per ss Sample")
    plt.grid(True, which="major", alpha=0.5)
    plt.grid(True, which="minor", alpha=0.2)
    plt.legend(fontsize=8)
    plt.savefig(
        os.path.join(path, "retrans_delta.png"),
        dpi=150,
        bbox_inches="tight"
    )
    plt.close()


def main():

    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <out_dir>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]

    log_file = os.path.join(path, "ss_tcpinfo.log")

    if not os.path.exists(log_file):
        print(f"ERROR: {log_file} not found", file=sys.stderr)
        sys.exit(1)

    csv_file = os.path.join(path, "retrans.csv")

    df = parse_ss_retrans(log_file)
    df.to_csv(csv_file, index=False)

    plot_retrans(df, os.path.join(path, "retrans"), path=path)

    print(f"Saved CSV: {csv_file}")
    print(f"Saved plots:")
    print(f"  {os.path.join(path, 'retrans_cumulative.png')}")
    print(f"  {os.path.join(path, 'retrans_delta.png')}")


if __name__ == "__main__":
    main()