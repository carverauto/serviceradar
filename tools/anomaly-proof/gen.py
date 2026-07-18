#!/usr/bin/env python3
# Copyright 2026 Carver Automation Corporation.
# SPDX-License-Identifier: Apache-2.0
"""
Synthetic metrics generator for the ServiceRadar anomaly proof harness.

Goal: produce REALISTIC, LABELED time series for the metric shapes the engine
actually scores — bounded percent gauges (CPU/mem) and a monotonic SNMP counter
(ifHCInOctets) — with anomalies injected at known timestamps so detection is
*measurable* (precision/recall/latency), not asserted.

The series are written in the exact JSONL contract that the REAL detector binary
`rust/anomaly-core/src/bin/anomaly-backtest` consumes:

    {"series_key": "<key>", "value": <f64>, "observed_at_unix_nano": <u64>}

so the proof runs through shipping code, not a reimplementation.

Outputs (under --outdir, default ./out):
    samples.jsonl  -- all series interleaved, time-ordered (feed to anomaly-backtest)
    truth.csv      -- ground-truth labels: series_key,i,t_ns,value,is_truth,klass

Injected anomaly classes (and what each is meant to prove about a plain z-score):
    spike              one-off sustained burst        -> SHOULD detect (its strength)
    blip               single-sample excursion        -> should NOT confirm (hysteresis)
    step               sudden sustained level shift    -> SHOULD detect (+ recovery edge)
    drift / leak       slow monotone ramp             -> usually MISSED (self-masking)
    recurring_diurnal nightly scheduled load           -> expected operation;
                                                          every spike alert is a
                                                          truth-labeled false positive
    counter_raw        monotonic counter fed raw       -> GARBAGE without rate-norm
"""
import argparse
import csv
import json
import math
import os

import numpy as np

# Fixed epoch so runs are byte-reproducible (a Monday 00:00 UTC-ish anchor).
START_NS = 1_700_000_000 * 1_000_000_000
WEEKEND_DOW = {5, 6}


def raised_cosine(minute_of_day, amp, peak_hour):
    """Smooth diurnal bump: == amp at peak_hour, == 0 twelve hours later."""
    phase = 2.0 * np.pi * (minute_of_day / 1440.0) - 2.0 * np.pi * (peak_hour / 24.0)
    return amp * 0.5 * (1.0 + np.cos(phase))


def time_axes(n, cadence_s):
    i = np.arange(n)
    minute_of_day = (i * cadence_s / 60.0) % 1440.0
    dow = ((i * cadence_s) // 86400) % 7
    return i, minute_of_day, dow


def add_event(values, truth, klass, start, length, delta):
    """Additively inject an anomaly over [start, start+length) and label it."""
    end = min(start + length, len(values))
    if isinstance(delta, np.ndarray):
        values[start:end] += delta[: end - start]
    else:
        values[start:end] += delta
    truth[start:end] = 1
    # record class on the labeled span (last writer wins on overlap; we don't overlap)
    for j in range(start, end):
        klass[j] = klass[j] or ""
    return start, end


def nightly_spikes(n, cadence_s, hour, length_min, amp):
    """Return an additive array with a recurring spike each day at `hour`."""
    spd = int(round(86400 / cadence_s))               # samples per day
    off = int(round(hour * 3600 / cadence_s))         # sample offset into the day
    length = max(1, int(round(length_min * 60 / cadence_s)))
    arr = np.zeros(n)
    spans = []
    d = 0
    while True:
        start = d * spd + off
        if start >= n:
            break
        end = min(start + length, n)
        arr[start:end] += amp
        spans.append((start, end))
        d += 1
    return arr, spans


def build_cpu(n, cadence_s, rng):
    _, mod, dow = time_axes(n, cadence_s)
    weekend = np.isin(dow, list(WEEKEND_DOW))
    weekly = np.where(weekend, 0.55, 1.0)
    base = 18.0 + raised_cosine(mod, 22.0, peak_hour=13.0) * weekly
    noise = rng.normal(0.0, 2.5, n)
    values = base + noise
    truth = np.zeros(n, dtype=int)
    klass = [""] * n

    spd = int(round(86400 / cadence_s))

    # Recurring nightly backup at 02:00 (+35 for 20 min) is expected operation,
    # not an incident. Keep a negative class label on every sample so the
    # committed scorecard can enforce that production spike policy suppresses
    # these alerts instead of silently counting them as true positives.
    nightly, spans = nightly_spikes(n, cadence_s, hour=2.0, length_min=20, amp=35.0)
    values += nightly
    for (s, e) in spans:
        for j in range(s, e):
            klass[j] = "recurring_diurnal_fp"

    # one-off sustained spike in week 2, Tue ~10:30 (+55 for 12 min)
    s = 8 * spd + int(round(10.5 * 3600 / cadence_s))
    add_event(values, truth, klass, s, 12, 55.0)
    for j in range(s, min(s + 12, n)):
        klass[j] = "spike"

    # single-sample blip (Wed ~15:00) — must NOT confirm with confirm_slots=5
    s = 9 * spd + int(round(15.0 * 3600 / cadence_s))
    add_event(values, truth, klass, s, 1, 55.0)
    klass[s] = "blip"

    # sustained step (+28 for 2h, Thu ~09:00)
    s = 10 * spd + int(round(9.0 * 3600 / cadence_s))
    add_event(values, truth, klass, s, 120, 28.0)
    for j in range(s, min(s + 120, n)):
        klass[j] = "step"

    # slow drift (Fri ~08:00, +0.18/sample for 300 then plateau) — the blind spot
    s = 11 * spd + int(round(8.0 * 3600 / cadence_s))
    ramp = np.minimum(np.arange(300) * 0.18, 54.0)
    add_event(values, truth, klass, s, 300, ramp)
    for j in range(s, min(s + 300, n)):
        klass[j] = "drift"

    # self-masking probe (0.7 / D-Q2): a big spike, then a second spike 20 samples
    # later — does the first spike's variance inflation mask the second? The
    # withhold-from-baseline rule should keep the second one detectable; the harness
    # decides whether a robust median/MAD estimator is actually needed (2.1).
    s = 16 * spd + int(round(3.0 * 3600 / cadence_s))  # Sun 03:00 (quiet)
    add_event(values, truth, klass, s, 8, 60.0)
    for j in range(s, min(s + 8, n)):
        klass[j] = "selfmask_a"
    s2 = s + 20
    add_event(values, truth, klass, s2, 8, 38.0)
    for j in range(s2, min(s2 + 8, n)):
        klass[j] = "selfmask_b"

    return np.clip(values, 1.0, 99.0), truth, klass


def build_mem(n, cadence_s, rng):
    _, mod, dow = time_axes(n, cadence_s)
    base = 55.0 + raised_cosine(mod, 6.0, peak_hour=15.0)
    values = base + rng.normal(0.0, 1.5, n)
    truth = np.zeros(n, dtype=int)
    klass = [""] * n
    spd = int(round(86400 / cadence_s))

    # slow memory leak that does NOT self-heal: +0.012/sample for 1500 samples
    # (~25h) then HOLDS at +18 to the end of the series (only a restart clears a
    # real leak). Truth-label the rising ramp (the detection target); the elevated
    # plateau that follows is deliberately unlabeled — the detector adapts to it as
    # the new normal, which is itself an honest limitation worth seeing.
    s = 6 * spd + int(round(12.0 * 3600 / cadence_s))
    ramp_len = 1500
    leak = np.zeros(n)
    leak[s:s + ramp_len] = np.minimum(np.arange(ramp_len) * 0.012, 18.0)
    leak[s + ramp_len:] = 18.0
    values += leak
    truth[s:s + ramp_len] = 1
    for j in range(s, min(s + ramp_len, n)):
        klass[j] = "leak"

    # one sudden step (+18 for 1h)
    s = 13 * spd + int(round(11.0 * 3600 / cadence_s))
    add_event(values, truth, klass, s, 60, 18.0)
    for j in range(s, min(s + 60, n)):
        klass[j] = "step"

    return np.clip(values, 1.0, 99.0), truth, klass


def build_disk(n, cadence_s, rng):
    """Disk used_percent — isolates the directional 80% saturation gate.

    Two SHARP, z-catchable bumps that differ ONLY in absolute level:
      benign_sub80  45% -> ~72%  : a plain z-score flags it; the 80% gate suppresses it
      disk_high     45% -> ~88%  : above 80%, so the gate allows the breach
    Run the same series with and without --saturation-gate-min 80 to see the gate.
    """
    _, mod, _ = time_axes(n, cadence_s)
    base = 45.0 + raised_cosine(mod, 4.0, peak_hour=12.0)
    values = base + rng.normal(0.0, 1.5, n)
    truth = np.zeros(n, dtype=int)
    klass = [""] * n
    spd = int(round(86400 / cadence_s))

    # benign sub-80 sharp bump — pure z flags it, but it is NOT an incident (gate suppresses)
    s = 7 * spd + int(round(10.0 * 3600 / cadence_s))
    add_event(values, truth, klass, s, 15, 27.0)
    truth[s:s + 15] = 0  # benign: deliberately unlabeled
    for j in range(s, min(s + 15, n)):
        klass[j] = "benign_sub80"

    # genuine high-utilization excursion above 80% — the real incident
    s = 12 * spd + int(round(14.0 * 3600 / cadence_s))
    add_event(values, truth, klass, s, 15, 43.0)
    for j in range(s, min(s + 15, n)):
        klass[j] = "disk_high"

    return np.clip(values, 1.0, 99.0), truth, klass


def build_snmp(n, cadence_s, rng):
    """Return (rate_norm, rate_truth, rate_klass, counter_raw)."""
    _, mod, dow = time_axes(n, cadence_s)
    weekend = np.isin(dow, list(WEEKEND_DOW))
    weekly = np.where(weekend, 0.5, 1.0)
    rate_true = 6.0e6 + raised_cosine(mod, 4.0e6, peak_hour=14.0) * weekly
    rate_true = np.maximum(rate_true + rng.normal(0.0, 3.0e5, n), 1.0e5)

    truth = np.zeros(n, dtype=int)
    klass = [""] * n
    spd = int(round(86400 / cadence_s))

    # sustained traffic burst x4 (Wed ~13:00 for 90 min)
    s = 9 * spd + int(round(13.0 * 3600 / cadence_s))
    e = min(s + 90, n)
    rate_true[s:e] *= 4.0
    truth[s:e] = 1
    for j in range(s, e):
        klass[j] = "burst"

    # integrate to a cumulative monotonic counter, then inject a reset (reboot)
    cumulative = np.cumsum(rate_true * cadence_s)
    reset_at = 16 * spd + int(round(4.0 * 3600 / cadence_s))
    cumulative[reset_at:] -= cumulative[reset_at - 1]  # counter restarts near 0

    # rate-normalize the way the addon CounterNormalizer would (delta/elapsed,
    # salvage a reset by carrying the previous good rate instead of a fake spike)
    delta = np.diff(cumulative, prepend=cumulative[0])
    rate_norm = delta / cadence_s
    rate_norm[0] = rate_true[0]
    for j in range(1, n):
        if delta[j] < 0:  # reset / wrap discontinuity -> addon would gap; we carry
            rate_norm[j] = rate_norm[j - 1]
    return rate_norm, truth, klass, cumulative


def write_outputs(outdir, series, cadence_s):
    os.makedirs(outdir, exist_ok=True)
    n = len(next(iter(series.values()))["values"])
    samples_path = os.path.join(outdir, "samples.jsonl")
    truth_path = os.path.join(outdir, "truth.csv")

    with open(samples_path, "w") as sf, open(truth_path, "w", newline="") as tf:
        tw = csv.writer(tf)
        tw.writerow(["series_key", "i", "t_ns", "value", "is_truth", "klass"])
        for i in range(n):
            t_ns = START_NS + i * cadence_s * 1_000_000_000
            for key, spec in series.items():
                v = float(spec["values"][i])
                sf.write(json.dumps({
                    "series_key": key,
                    "value": v,
                    "observed_at_unix_nano": t_ns,
                }))
                sf.write("\n")
                tw.writerow([key, i, t_ns, f"{v:.6g}",
                             int(spec["truth"][i]), spec["klass"][i]])
    return samples_path, truth_path, n


def main():
    ap = argparse.ArgumentParser(description="ServiceRadar anomaly proof — synthetic generator")
    ap.add_argument("--weeks", type=float, default=3.0, help="duration in weeks")
    ap.add_argument("--cadence-s", type=int, default=60, help="seconds between samples")
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(__file__), "out"))
    args = ap.parse_args()

    n = int(round(args.weeks * 7 * 86400 / args.cadence_s))
    rng = np.random.default_rng(args.seed)

    cpu_v, cpu_t, cpu_k = build_cpu(n, args.cadence_s, rng)
    mem_v, mem_t, mem_k = build_mem(n, args.cadence_s, rng)
    disk_v, disk_t, disk_k = build_disk(n, args.cadence_s, rng)
    rate_v, rate_t, rate_k, counter_raw = build_snmp(n, args.cadence_s, rng)

    series = {
        "cpu.usage_percent": {"values": cpu_v, "truth": cpu_t, "klass": cpu_k, "kind": "gauge"},
        "memory.usage_percent": {"values": mem_v, "truth": mem_t, "klass": mem_k, "kind": "gauge"},
        "disk.usage_percent": {"values": disk_v, "truth": disk_t, "klass": disk_k, "kind": "gauge"},
        "snmp.if1.rate_bps": {"values": rate_v, "truth": rate_t, "klass": rate_k, "kind": "rate"},
        # raw counter fed straight in — no truth labels; every flag is a contract-violation FP
        "snmp.if1.counter_raw": {"values": counter_raw,
                                  "truth": np.zeros(n, dtype=int),
                                  "klass": [""] * n, "kind": "counter_raw"},
    }

    samples_path, truth_path, n = write_outputs(args.outdir, series, args.cadence_s)
    total_truth = sum(int(s["truth"].sum()) for s in series.values())
    print(f"generated {n} samples/series x {len(series)} series "
          f"({args.weeks} weeks @ {args.cadence_s}s)")
    print(f"  samples -> {samples_path}")
    print(f"  truth   -> {truth_path}  ({total_truth} labeled anomalous samples)")
    for key, spec in series.items():
        print(f"  {key:24s} kind={spec['kind']:11s} truth_samples={int(spec['truth'].sum())}")


if __name__ == "__main__":
    main()
