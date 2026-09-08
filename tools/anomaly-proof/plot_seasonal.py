#!/usr/bin/env python3
# Copyright 2026 Carver Automation Corporation.
# SPDX-License-Identifier: Apache-2.0
"""
Plot + score the CORE seasonal-disposition proof.

Reads:
    out/seasonal_profile.csv  the 168-bucket hour-of-week baseline (for the curve)
    out/seasonal_out.csv      dispositions from the REAL dispose_seasonal kernel
    out/seasonal_truth.csv    expected disposition per labeled test case

Produces:
    out/seasonal_proof.png    the hour-of-week baseline band + test points by verdict
    a pass/fail scorecard (expected vs. actual disposition), printed
"""
import csv
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "out")
N_SIGMA = 3.0
COLORS = {
    "suppress": "#2ca02c",
    "seasonal_breach": "#d62728",
    "seasonal_drift": "#e08214",
    "insufficient_baseline": "#7f7f7f",
    "skipped": "#9467bd",
}


def read_csv(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def main():
    profile = read_csv(os.path.join(OUT, "seasonal_profile.csv"))
    how = np.array([int(r["how"]) for r in profile])
    mean = np.array([float(r["mean"]) for r in profile])
    std = np.array([float(r["std"]) for r in profile])
    order = np.argsort(how)
    how, mean, std = how[order], mean[order], std[order]

    out = {r["series_key"]: r for r in read_csv(os.path.join(OUT, "seasonal_out.csv"))}
    truth = read_csv(os.path.join(OUT, "seasonal_truth.csv"))

    fig, ax = plt.subplots(figsize=(15, 6))
    ax.plot(how, mean, color="#1f3b57", lw=1.3, zorder=2, label="hour-of-week baseline (mean)")
    ax.fill_between(how, mean - N_SIGMA * std, mean + N_SIGMA * std,
                    color="#9ecae1", alpha=0.35, lw=0, zorder=1,
                    label=f"seasonal expected ±{N_SIGMA:g}σ")

    rows = []
    npass = 0
    for t in truth:
        key = t["series_key"]
        dow, hod = int(t["dow"]), int(t["hod"])
        x = dow * 24 + hod
        y = float(t["sample_value"])
        expected = t["expected"]
        o = out.get(key, {})
        actual = o.get("disposition", "MISSING")
        score = float(o.get("score", 0.0))
        ok = (actual == expected)
        npass += ok
        rows.append((key, expected, actual, score, ok, float(t["base_mean"])))

        color = COLORS.get(actual, "#000000")
        ax.scatter([x], [y], s=90, color=color, edgecolor="black" if ok else "red",
                   linewidth=1.0 if ok else 2.2, zorder=5)
        ax.annotate(f"{key}\n{actual} z={score:.1f}", (x, y),
                    textcoords="offset points", xytext=(6, 6), fontsize=7,
                    color=color)

    for d in range(8):
        ax.axvline(d * 24, color="#cccccc", lw=0.6, zorder=0)
    ax.set_xticks([d * 24 + 12 for d in range(7)])
    ax.set_xticklabels(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    ax.set_xlim(-1, 168)
    ax.set_ylabel("value (%)")
    ax.set_title("ServiceRadar core seasonal disposition — REAL dispose_seasonal kernel over a "
                 "168-bucket hour-of-week baseline\n"
                 "green=suppress (seasonal-normal) · red=seasonal_breach · gray=insufficient · "
                 "red outline=verdict != expected", fontsize=10)
    handles = [plt.Line2D([0], [0], marker="o", ls="", color=c, label=k)
               for k, c in COLORS.items()]
    ax.legend(handles=ax.get_legend_handles_labels()[0] + handles, fontsize=7, loc="upper right")
    ax.grid(True, alpha=0.15)
    fig.tight_layout()
    png = os.path.join(OUT, "seasonal_proof.png")
    fig.savefig(png, dpi=120)

    print(f"figure -> {png}\n")
    print(f"{'test case':26s} {'expected':22s} {'actual':22s} {'z':>6s}  result")
    print("-" * 90)
    for key, expected, actual, score, ok, base in rows:
        print(f"{key:26s} {expected:22s} {actual:22s} {score:6.2f}  {'PASS' if ok else 'FAIL <<<'}")
    print("-" * 90)
    print(f"{npass}/{len(rows)} cases matched the expected disposition")


if __name__ == "__main__":
    main()
