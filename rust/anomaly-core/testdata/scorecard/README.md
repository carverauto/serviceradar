# Labeled scorecard corpus (CI floor gate)

The committed, deterministic synthetic corpus behind the scorecard floor gate
`//rust/anomaly-core:scorecard_gate_test` (`tests/scorecard_gate.rs`) and the
`anomaly-backtest --truth` scoring mode — OpenSpec
`overhaul-anomaly-engine-reliability` task 1.20.c.

## Provenance / regeneration

Generated ONCE by the anomaly proof harness generator at its documented
defaults and committed gzipped. To regenerate byte-identically (verified: two
runs produce identical sha256), from the repo root:

```bash
python3 tools/anomaly-proof/gen.py --seed 1234 --weeks 3 --cadence-s 60 --outdir /tmp/scorecard-corpus
gzip -9 -n -c /tmp/scorecard-corpus/samples.jsonl > rust/anomaly-core/testdata/scorecard/samples.jsonl.gz
gzip -9 -n -c /tmp/scorecard-corpus/truth.csv    > rust/anomaly-core/testdata/scorecard/truth.csv.gz
```

Uncompressed sha256 (2026-07-12, numpy 2.4.6 — `np.random.default_rng(1234)`
is the only entropy source and is version-stable):

- `samples.jsonl` (16.9 MB): `c52bc65895f4618552cb18928c833e16b069993301ed48c1d408ab38ee0ba8ae`
- `truth.csv` (8.9 MB): `d23a16e60edf23068e96e497b30c0d79d3bab3081be7877c05e80c76fdde71c8`

Contents: 30,240 samples x 5 series (3 weeks @ 60s cadence), 2,534 labeled
anomalous samples. Series: `cpu.usage_percent`, `memory.usage_percent`,
`disk.usage_percent` (gauges), `snmp.if1.rate_bps` (rate-normalized), and
`snmp.if1.counter_raw` (a deliberately-wrong raw monotonic counter — zero
truth labels, every flag is a contract-violation FP). Injected classes:
spike, blip, step, drift, leak, recurring_seasonal, burst, benign_sub80,
disk_high, selfmask_a/b, plus a counter reset. See `tools/anomaly-proof/gen.py`
for the exact injection schedule.

## Measured baseline (2026-07-12, this corpus, detector defaults + `--cusum`)

| Metric | Measured | CI floor/ceiling |
|---|---|---|
| Spike precision (cpu + mem + rate, ungated) | 834 TP / 0 FP = **1.000** | >= 0.98 |
| z-catchable span recall (cpu spike/step, mem step, rate burst) | **4/4**, median latency 4 samples | all detected |
| cpu single-blip (hysteresis) | **0/1** confirmed | must stay 0 |
| Deseasonalized CUSUM drift recall (cpu 300-sample ramp) | **230/300** = 0.767, first alarm +20 | >= 0.75, first <= +40 |
| CUSUM drift FP rate, clean seasonal series | cpu **0.44%**, rate **0.99%** | <= 1% |
| Max abs score, all 5 series | **44.65**, all finite | <= 50 |
| disk under saturation gate 80 | 11 TP / **0 FP**, disk_high 1/1 | 0 FP, 1/1 |

Known measured exclusions (deliberately NOT gated; rationale in
`tests/scorecard_gate.rs`): memory CUSUM FP 38.1% (2-week leak in a 3-week
window — needs the core 180-day robust profile), disk CUSUM FP 1.08% (the
benign unlabeled bumps; covered by the gate proof instead), counter_raw
(garbage-in demo).

The historical `216/300` drift-recall figure in `tools/anomaly-proof/README.md`
came from an earlier detector state; this corpus + the current kernels measure
230/300, and the gate is baselined against the re-measured numbers.

## Reproduce the scorecard by hand

```bash
cargo run --manifest-path rust/anomaly-core/Cargo.toml --bin anomaly-backtest -- \
    --input rust/anomaly-core/testdata/scorecard/samples.jsonl.gz \
    --truth rust/anomaly-core/testdata/scorecard/truth.csv.gz \
    --cusum
```

## Honesty caveat

This gate proves the anomaly-core kernels (rolling robust z-score, confirm
hysteresis, saturation gate, CUSUM) plus the backtest CLI's hour-of-week-median
deseasonalization plumbing. It does NOT exercise the addon frame path
(cooldown, shed accounting, rollups) — that coverage lives in the
`rust/anomaly-addon` in-crate tests tracked as tasks 1.20.a/1.20.b.
