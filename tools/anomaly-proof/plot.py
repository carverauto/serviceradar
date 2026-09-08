#!/usr/bin/env python3
# Copyright 2026 Carver Automation Corporation.
# SPDX-License-Identifier: Apache-2.0
"""
Plot + score the ServiceRadar anomaly proof harness.

Reads:
    out/truth.csv        ground-truth labels from gen.py
    out/verdicts.jsonl   per-sample verdicts from the REAL anomaly-backtest binary
                         (run with `--emit all` so every sample has a verdict)

Produces:
    out/anomaly_proof.png   Twitter-AnomalyDetection-Fig2-style figure per series
    out/scorecard.json      per-class precision/recall/latency, printed too

Because the anomalies are labeled, detection is *measured*, not asserted. The
shaded baseline band is a VISUALIZATION AID reconstructed in numpy; the red/orange
flags come from the shipping detector, not from this script.
"""
import csv
import json
import math
import os
from collections import OrderedDict, defaultdict

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime, timezone

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "out")
WINDOW = 300          # matches anomaly-backtest default --window-size
N_SIGMA = 3.0         # matches default --n-sigma (band is a viz aid only)
LATENCY_TOL = 8       # samples of grace when matching a flag to a truth span


def load_truth(path):
    series = OrderedDict()
    with open(path) as f:
        for row in csv.DictReader(f):
            k = row["series_key"]
            d = series.setdefault(k, {"i": [], "t_ns": [], "value": [], "truth": [], "klass": []})
            d["i"].append(int(row["i"]))
            d["t_ns"].append(int(row["t_ns"]))
            d["value"].append(float(row["value"]))
            d["truth"].append(int(row["is_truth"]))
            d["klass"].append(row["klass"])
    for d in series.values():
        for kk in ("i", "t_ns", "value", "truth"):
            d[kk] = np.array(d[kk])
    return series


def load_verdicts(path):
    """Per series_key, verdict fields in input (i-) order."""
    v = defaultdict(lambda: {"anomalous": [], "breached": [], "score": [], "state": []})
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            k = o["series_key"]
            v[k]["anomalous"].append(bool(o["anomalous"]))
            v[k]["breached"].append(bool(o["breached"]))
            v[k]["score"].append(float(o.get("score", 0.0)))
            v[k]["state"].append(o.get("state", ""))
    for d in v.values():
        d["anomalous"] = np.array(d["anomalous"])
        d["breached"] = np.array(d["breached"])
        d["score"] = np.array(d["score"])
    return v


def truth_spans(truth, klass):
    spans = []
    n = len(truth)
    i = 0
    while i < n:
        if truth[i]:
            j = i
            kl = klass[i]
            while j < n and truth[j] and klass[j] == kl:
                j += 1
            spans.append((i, j, kl))
            i = j
        else:
            i += 1
    return spans


def score_series(truth, klass, anomalous):
    spans = truth_spans(truth, klass)
    flagged = np.where(anomalous)[0]

    # recall per span (detected if any confirmed flag inside [start, end+tol))
    per_class = defaultdict(lambda: {"spans": 0, "detected": 0, "latencies": []})
    detected_spans = []
    for (s, e, kl) in spans:
        per_class[kl]["spans"] += 1
        hits = flagged[(flagged >= s) & (flagged < e + LATENCY_TOL)]
        if hits.size:
            per_class[kl]["detected"] += 1
            per_class[kl]["latencies"].append(int(hits[0] - s))
            detected_spans.append((s, e + LATENCY_TOL))

    # precision: a flag is TP if it lands in any truth span (± tol), else FP
    tp = fp = 0
    for idx in flagged:
        if any(s <= idx < e + LATENCY_TOL for (s, e, _kl) in spans):
            tp += 1
        else:
            fp += 1
    precision = tp / (tp + fp) if (tp + fp) else float("nan")

    out = {"precision": precision, "flags": int(flagged.size),
           "tp_flags": tp, "fp_flags": fp, "by_class": {}}
    for kl, d in per_class.items():
        recall = d["detected"] / d["spans"] if d["spans"] else float("nan")
        lat = d["latencies"]
        out["by_class"][kl or "(unlabeled)"] = {
            "spans": d["spans"], "detected": d["detected"], "recall": recall,
            "median_latency_samples": (int(np.median(lat)) if lat else None),
        }
    return out, spans


def trailing_band(x, w, n_sigma):
    n = len(x)
    c = np.concatenate([[0.0], np.cumsum(x)])
    csq = np.concatenate([[0.0], np.cumsum(x * x)])
    mean = np.full(n, np.nan)
    std = np.full(n, np.nan)
    for i in range(n):
        lo = max(0, i - w + 1)
        cnt = i + 1 - lo
        m = (c[i + 1] - c[lo]) / cnt
        var = max((csq[i + 1] - csq[lo]) / cnt - m * m, 0.0)
        mean[i] = m
        std[i] = math.sqrt(var)
    return mean, mean - n_sigma * std, mean + n_sigma * std


def main():
    truth = load_truth(os.path.join(OUT, "truth.csv"))
    verdicts = load_verdicts(os.path.join(OUT, "verdicts.jsonl"))

    keys = list(truth.keys())
    fig, axes = plt.subplots(len(keys), 1, figsize=(16, 3.1 * len(keys)), sharex=True)
    if len(keys) == 1:
        axes = [axes]

    scorecard = {}
    for ax, k in zip(axes, keys):
        d = truth[k]
        v = verdicts.get(k, {"anomalous": np.zeros(len(d["i"]), bool),
                             "breached": np.zeros(len(d["i"]), bool)})
        m = min(len(d["value"]), len(v["anomalous"]))
        value = d["value"][:m]
        t = np.array([datetime.fromtimestamp(ns / 1e9, tz=timezone.utc) for ns in d["t_ns"][:m]])
        anomalous = v["anomalous"][:m]
        breached = v["breached"][:m]
        klass = d["klass"][:m]
        tr = d["truth"][:m]

        sc, spans = score_series(tr, klass, anomalous)
        scorecard[k] = sc

        ax.plot(t, value, lw=0.6, color="#1f3b57", zorder=2)
        if k != "snmp.if1.counter_raw":  # band is meaningless on a raw counter
            _mean, lo, hi = trailing_band(value, WINDOW, N_SIGMA)
            ax.fill_between(t, lo, hi, color="#9ecae1", alpha=0.30, lw=0,
                            zorder=1, label=f"~rolling ±{N_SIGMA:g}σ (viz aid)")
        for (s, e, kl) in spans:
            ax.axvspan(t[s], t[min(e, m - 1)], color="#ffd9a0", alpha=0.45, zorder=0)
        bo = breached & ~anomalous
        if bo.any():
            ax.scatter(t[bo], value[bo], s=12, marker="x", color="#e08214",
                       zorder=3, label="breach (not confirmed)")
        if anomalous.any():
            ax.scatter(t[anomalous], value[anomalous], s=16, color="#d62728",
                       zorder=4, label="confirmed anomaly")

        cls = ", ".join(f"{c}:{x['detected']}/{x['spans']}" for c, x in sc["by_class"].items())
        ax.set_title(f"{k}   precision={sc['precision']:.2f}  flags={sc['flags']} "
                     f"(TP {sc['tp_flags']} / FP {sc['fp_flags']})   recall[{cls}]",
                     fontsize=9, loc="left")
        ax.legend(loc="upper right", fontsize=7, framealpha=0.9)
        ax.grid(True, alpha=0.2)

    axes[-1].xaxis.set_major_formatter(mdates.DateFormatter("%a %d\n%H:%M"))
    fig.suptitle("ServiceRadar anomaly proof — real rust/anomaly-core detector over labeled synthetic data\n"
                 "shaded span = injected ground truth · red = confirmed · orange x = breach-not-confirmed",
                 fontsize=11)
    fig.tight_layout(rect=[0, 0, 1, 0.97])
    png = os.path.join(OUT, "anomaly_proof.png")
    fig.savefig(png, dpi=120)

    with open(os.path.join(OUT, "scorecard.json"), "w") as f:
        json.dump(scorecard, f, indent=2)

    print(f"figure -> {png}\n")
    for k, sc in scorecard.items():
        print(f"### {k}")
        print(f"    precision={sc['precision']:.3f}  flags={sc['flags']} "
              f"(TP {sc['tp_flags']} / FP {sc['fp_flags']})")
        for c, x in sc["by_class"].items():
            lat = x["median_latency_samples"]
            lat_s = f", median latency {lat} samples" if lat is not None else ""
            print(f"      {c:20s} recall {x['detected']}/{x['spans']} = "
                  f"{x['recall']:.2f}{lat_s}")
        print()


if __name__ == "__main__":
    main()
