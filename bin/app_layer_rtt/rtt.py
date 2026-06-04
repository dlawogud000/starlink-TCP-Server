import os
import sys
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import ticker

if len(sys.argv) < 2:
    print("Usage: python3 plot_rtt_csv.py <csv_file>")
    sys.exit(1)

csv_file = sys.argv[1]

df = pd.read_csv(csv_file)

# seq 기준 10ms 간격 시간축
df["time_s"] = df["seq"] * 0.01

# timeout 또는 ok가 아닌 경우 RTT=0
df["plot_rtt_ms"] = df.apply(
    lambda row: row["rtt_ms"] if str(row["status"]).lower() == "ok" else 0.0,
    axis=1
)

base_name = os.path.splitext(os.path.basename(csv_file))[0]
output_png = f"{base_name}_rtt.png"

plt.figure(figsize=(14, 5))
plt.plot(df["time_s"], df["plot_rtt_ms"], linewidth=0.8)

ax = plt.gca()
ax.xaxis.set_major_locator(ticker.MultipleLocator(10))
ax.xaxis.set_minor_locator(ticker.MultipleLocator(1))
ax.set_ylim(bottom=50, top=max(350, df["plot_rtt_ms"].max()))

plt.xlabel("Time (s)")
plt.ylabel("RTT (ms)")
plt.title(f"RTT over Time - {base_name}")
plt.grid(True)

plt.tight_layout()
plt.savefig(output_png, dpi=300)
plt.show()

print(f"Saved: {output_png}")