#!/usr/bin/env python3
# Copyright 2026 Carver Automation Corporation.
# SPDX-License-Identifier: Apache-2.0
"""
Synthetic generator for the CORE capacity-forecast proof.

Emits a disk-fill series as the long-format point contract the real
`dispose_capacity` kernel consumes (series_key,at_unix_micros,value): a slow
linear climb toward 100% with noise, enough history that a multi-month horizon
makes sense. Used to show (a) the forecast/ETA works, and (b) the audit's
overclaim — lower/upper = projected +/- 1.96*RMSE is a CONSTANT width regardless
of how far out you project (run the same series at 7d and 90d horizons).
"""
import argparse
import csv
import os

import numpy as np

START_MICROS = 1_700_000_000 * 1_000_000  # fixed epoch, unix microseconds


def main():
    ap = argparse.ArgumentParser(description="core capacity-forecast synthetic generator")
    ap.add_argument("--days", type=int, default=40, help="days of hourly history")
    ap.add_argument("--slope-per-hour", type=float, default=0.020, help="%/hour fill rate")
    ap.add_argument("--start", type=float, default=40.0, help="starting used percent")
    ap.add_argument("--noise", type=float, default=1.5)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(__file__), "out"))
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    os.makedirs(args.outdir, exist_ok=True)

    n = args.days * 24
    i = np.arange(n)
    value = np.clip(args.start + args.slope_per_hour * i + rng.normal(0, args.noise, n), 0, 100)

    path = os.path.join(args.outdir, "capacity_points.csv")
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["series_key", "at_unix_micros", "value"])
        for k in range(n):
            w.writerow(["disk_fill", START_MICROS + int(i[k]) * 3600 * 1_000_000, f"{value[k]:.6f}"])

    print(f"{n} hourly points ({args.days}d) start={args.start}% slope={args.slope_per_hour}%/h "
          f"end~{value[-1]:.1f}% -> {path}")


if __name__ == "__main__":
    main()
