#!/usr/bin/env python3
# Copyright 2026 Carver Automation Corporation.
# SPDX-License-Identifier: Apache-2.0
"""
Synthetic generator for the CORE seasonal-disposition proof.

Reproduces what the `profile_hour_of_week` SQL aggregate feeds the real Rust
`dispose_seasonal` kernel: a 168-bucket (dow x hod) historical baseline plus a
"latest complete bucket" value under test. Emits the kernel's SeasonalRow CSV
contract (MeanStddev: bucket_count/sum/sum_sq INCLUDE the latest sample; the
kernel de-aggregates it to form the excluded baseline).

The marquee case `nightly_normal`: the edge flags the 02:00 backup spike 21/21
nights (see the edge harness). Here the seasonal tier should SUPPRESS it, because
02:00 is historically high for this series — "edge over-alerts, core disposes."

Outputs (under --outdir):
    seasonal_profile.csv  168 buckets: dow,hod,how,mean,std  (for the baseline plot)
    seasonal_rows.csv     SeasonalRow inputs for disposition-backtest
    seasonal_truth.csv    expected disposition per test case
"""
import argparse
import csv
import math
import os

import numpy as np


def profile_mean(dow, hod):
    """Historical hour-of-week mean for a CPU-like series with a weeknight backup."""
    weekend = dow in (5, 6)
    diurnal = 22.0 * 0.5 * (1 + math.cos(2 * math.pi * (hod / 24.0) - 2 * math.pi * (13 / 24.0)))
    base = (12.0 + diurnal * 0.55) if weekend else (18.0 + diurnal)
    nightly = 35.0 if (hod == 2 and not weekend) else 0.0  # 02:00 weeknight backup
    return base + nightly


# (series_key, dow, hod, sample_value | None=use baseline mean, expected disposition)
TESTS = [
    ("nightly_normal",            1, 2,  55.0, "suppress"),          # marquee: edge over-alerts, core suppresses
    ("nightly_anomaly",           1, 2,  92.0, "seasonal_breach"),   # genuinely high even for 02:00
    ("daytime_normal",            2, 13, 41.0, "suppress"),
    ("daytime_anomaly",           2, 13, 80.0, "seasonal_breach"),
    ("weekend_quiet_normal",      6, 4,  None, "suppress"),          # value == its low weekend baseline
    ("weekend_offcycle_anomaly",  6, 4,  70.0, "seasonal_breach"),   # high during a normally-quiet hour
    ("insufficient_baseline",     3, 7,  60.0, "insufficient_baseline"),  # too few historical samples
]


def main():
    ap = argparse.ArgumentParser(description="core seasonal-disposition synthetic generator")
    ap.add_argument("--weeks", type=int, default=8, help="historical weeks per bucket")
    ap.add_argument("--sigma", type=float, default=4.0, help="hour-to-hour stddev")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(__file__), "out"))
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    os.makedirs(args.outdir, exist_ok=True)

    buckets = {}
    profile_rows = []
    for dow in range(7):
        for hod in range(24):
            samples = profile_mean(dow, hod) + rng.normal(0.0, args.sigma, args.weeks)
            buckets[(dow, hod)] = samples
            profile_rows.append((dow, hod, dow * 24 + hod,
                                 float(np.mean(samples)), float(np.std(samples, ddof=1))))

    with open(os.path.join(args.outdir, "seasonal_profile.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["dow", "hod", "how", "mean", "std"])
        for dow, hod, how, mean, std in profile_rows:
            w.writerow([dow, hod, how, f"{mean:.6f}", f"{std:.6f}"])

    rows, truth = [], []
    for key, dow, hod, sample, expected in TESTS:
        base = buckets[(dow, hod)]
        if key == "insufficient_baseline":
            base = base[:2]  # fewer than min_bucket_samples (default 4)
        if sample is None:
            sample = float(np.mean(base))  # a value sitting AT the seasonal baseline
        hist_count = len(base)
        hist_sum = float(np.sum(base))
        hist_sum_sq = float(np.sum(base * base))
        center = float(np.median(base))
        mad = float(np.median(np.abs(base - center)))
        p05 = float(np.percentile(base, 5))
        p95 = float(np.percentile(base, 95))
        # MeanStddev contract: bucket_count/sum/sum_sq INCLUDE the latest sample.
        rows.append([key, dow, hod, f"{sample:.6f}",
                     hist_count + 1, f"{hist_sum + sample:.6f}",
                     f"{hist_sum_sq + sample * sample:.6f}",
                     f"{center:.6f}", f"{mad:.6f}", f"{p05:.6f}", f"{p95:.6f}", 0, 1])
        truth.append([key, dow, hod, f"{sample:.6f}", expected,
                      f"{float(np.mean(base)):.4f}", f"{float(np.std(base, ddof=1)):.4f}"])

    with open(os.path.join(args.outdir, "seasonal_rows.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["series_key", "dow", "hod", "sample_value", "bucket_count", "bucket_sum",
                    "bucket_sum_sq", "center", "mad", "p05", "p95",
                    "consecutive_anomalous", "baseline_excludes_latest"])
        w.writerows(rows)

    with open(os.path.join(args.outdir, "seasonal_truth.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["series_key", "dow", "hod", "sample_value", "expected", "base_mean", "base_std"])
        w.writerows(truth)

    print(f"168-bucket profile + {len(TESTS)} labeled test cases -> {args.outdir}")
    for key, dow, hod, sample, expected in TESTS:
        bm = float(np.mean(buckets[(dow, hod)][:2 if key == 'insufficient_baseline' else None]))
        sv = bm if sample is None else sample
        print(f"  {key:26s} (dow={dow},hod={hod:02d}) sample={sv:6.1f}  baseline~{bm:5.1f}  expect={expected}")


if __name__ == "__main__":
    main()
