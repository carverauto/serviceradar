#!/usr/bin/env python3
# Copyright 2026 Carver Automation Corporation.
# SPDX-License-Identifier: Apache-2.0
"""
Seed generator for the END-TO-END core seasonal proof against a real TimescaleDB.

Emits raw `timeseries_metrics` rows (the production hypertable feeding the
`timeseries_metrics_hourly` continuous aggregate) so the REAL SRQL
`profile_hour_of_week` verb can run over a real CAGG and produce the kernel's
SeasonalRow inputs — proving the F15 data feed end to end, not just the kernel.

Two devices share an identical hour-of-week history (CPU diurnal + a weeknight
02:00 backup bump). Their newest 02:00 bucket differs:
  dev-normal   : ~ its 02:00 baseline  -> expect the verb+kernel to SUPPRESS
  dev-anomaly  : 92%                    -> expect SEASONAL_BREACH

Output: out/timeseries_seed.csv  (timestamp,device_id,metric_type,metric_name,value)
"""
import argparse
import csv
import math
import os
from datetime import datetime, timezone

import numpy as np

START_EPOCH = 1704067200  # 2024-01-01 00:00:00 UTC (a Monday)
HOUR = 3600


def profile_mean(dow, hod):
    weekend = dow in (5, 6)
    diurnal = 22.0 * 0.5 * (1 + math.cos(2 * math.pi * (hod / 24.0) - 2 * math.pi * (13 / 24.0)))
    base = (12.0 + diurnal * 0.55) if weekend else (18.0 + diurnal)
    nightly = 35.0 if (hod == 2 and not weekend) else 0.0
    return base + nightly


def main():
    ap = argparse.ArgumentParser(description="end-to-end seasonal seed generator")
    ap.add_argument("--weeks", type=int, default=8)
    ap.add_argument("--sigma", type=float, default=4.0)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--metric-type", default="sysmon.cpu")
    ap.add_argument("--metric-name", default="cpu.usage_percent")
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(__file__), "out"))
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    os.makedirs(args.outdir, exist_ok=True)

    n = args.weeks * 7 * 24
    # latest test bucket: the Tuesday 02:00 of the week AFTER the full history
    latest_hour = args.weeks * 168 + 26  # Mon 00:00 + 1 day + 2 h
    devices = {"dev-normal": None, "dev-anomaly": 92.0}

    rows = []
    for dev, latest_override in devices.items():
        for h in range(n):
            dow = (h // 24) % 7
            hod = h % 24
            v = profile_mean(dow, hod) + rng.normal(0.0, args.sigma)
            ts = datetime.fromtimestamp(START_EPOCH + h * HOUR, tz=timezone.utc)
            rows.append([ts.isoformat(), dev, args.metric_type, args.metric_name, f"{max(v,0.0):.4f}"])
        # the latest 02:00 bucket
        dow, hod = (latest_hour // 24) % 7, latest_hour % 24
        v = latest_override if latest_override is not None else profile_mean(dow, hod) + rng.normal(0.0, args.sigma)
        ts = datetime.fromtimestamp(START_EPOCH + latest_hour * HOUR, tz=timezone.utc)
        rows.append([ts.isoformat(), dev, args.metric_type, args.metric_name, f"{max(v,0.0):.4f}"])

    path = os.path.join(args.outdir, "timeseries_seed.csv")
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["timestamp", "device_id", "metric_type", "metric_name", "value"])
        w.writerows(rows)

    print(f"{len(rows)} raw rows for {len(devices)} devices x {args.weeks} weeks -> {path}")
    print(f"  latest test bucket = hour {latest_hour} (dow={(latest_hour//24)%7}, hod={latest_hour%24})")
    print(f"  dev-normal latest ~baseline (expect suppress) · dev-anomaly latest=92 (expect breach)")


if __name__ == "__main__":
    main()
