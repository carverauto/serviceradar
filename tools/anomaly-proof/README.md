# anomaly-proof — a reproducible proof harness for the ServiceRadar anomaly engine

Runs the **real** detector code over **synthetic labeled** data so detection is
*measured* (precision / recall / latency), not asserted. Built to escape the
30-minute build→sign→deploy→edge-rollout loop: everything here runs locally in
seconds, with no production database.

This is the anti-hallucination gate for the `refactor-anomaly-engine-rigor`
OpenSpec change: every behavioral claim about the engine should have a scenario
here that proves it on shipping code.

## What it exercises

- **Edge half (no DB):** the real `rust/anomaly-core` detector via the
  `anomaly-backtest` binary. Synthetic CPU/mem/disk **gauges** and an SNMP
  **monotonic counter** (raw *and* correctly rate-normalized), with injected,
  ground-truth-labeled anomalies: spike, single-blip, step, slow drift/leak,
  recurring nightly (seasonal), a benign sub-80% disk bump, a real >80% disk
  fill, and a counter reset.
- **Core half (no DB):** the real Rust `dispose_seasonal` / `dispose_capacity`
  kernels via the `disposition-backtest` binary, over synthetic hour-of-week
  baselines and forecast points. Proves the seasonal tier *suppresses* the
  recurring-nightly load the edge over-alerts on, *flags* genuine off-baseline
  hours, and exposes the capacity band overclaim.
- **Core half (DB feed, planned):** the same kernels fed by the real SRQL
  `profile_hour_of_week` verb over a seeded TimescaleDB CAGG (the `srql-fixtures`
  CNPG scratch DB, or docker-compose `cnpg`), proving the data feed end to end.

## Prereqs

- Build the detector once: `cargo build --manifest-path rust/anomaly-core/Cargo.toml --bin anomaly-backtest`
  (binary lands at `target/debug/anomaly-backtest`).
- Python: `numpy`, `matplotlib`.

## Run (from repo root)

```bash
O=tools/anomaly-proof/out
python3 tools/anomaly-proof/gen.py --weeks 3
./target/debug/anomaly-backtest --input $O/samples.jsonl --emit all > $O/verdicts.jsonl
python3 tools/anomaly-proof/plot.py      # -> $O/anomaly_proof.png + $O/scorecard.json
```

### Disk saturation-gate proof (gate off vs on, same data)

```bash
grep '"disk.usage_percent"' $O/samples.jsonl > $O/disk.jsonl
./target/debug/anomaly-backtest --input $O/disk.jsonl --emit anomalies                          # fires sub-80 false alarms
./target/debug/anomaly-backtest --input $O/disk.jsonl --saturation-gate-min 80 --emit anomalies # gate suppresses them
```

### Core half — disposition kernels (no DB)

```bash
cargo build --manifest-path rust/causal-disposition/Cargo.toml --bin disposition-backtest

# seasonal: does the core tier suppress seasonal-normal and flag real deviations?
python3 tools/anomaly-proof/gen_seasonal.py
./target/debug/disposition-backtest --kind seasonal --input $O/seasonal_rows.csv > $O/seasonal_out.csv
python3 tools/anomaly-proof/plot_seasonal.py        # -> $O/seasonal_proof.png + scorecard

# capacity: forecast/ETA work, but the +/-1.96*RMSE band is a constant-width overclaim
python3 tools/anomaly-proof/gen_capacity.py
./target/debug/disposition-backtest --kind capacity --input $O/capacity_points.csv \
    --threshold 100 --model linear --horizon-seconds 7776000   # try 604800 / 2592000 too
```

## Proven results

| Series / class | What it proves | Result |
|---|---|---|
| CPU/SNMP spike, step, burst | the z-score's strength | recall **1/1**, ~4-sample latency, precision **1.0** |
| CPU nightly backup | the **seasonal** gap | flagged **21/21 nights** (the dispose target) |
| CPU single-blip | hysteresis (`confirm_slots`) | **0/1** — correctly not confirmed |
| CPU/mem slow drift & leak | the **drift blind spot** | **0/1 recall** — absorbed into the baseline |
| SNMP `counter_raw` | the data contract | **6,956 false alarms** vs rate-normalized **precision 1.0** |
| disk gate off → on | the 80% saturation gate | sub-80 false alarms 11 → **0**, real >80 kept 11 → 11 |
| core seasonal: nightly-normal | the open-loop fix target | **suppressed** (z=0) — the same spike the edge flags 21/21 |
| core seasonal: 7 labeled cases | the seasonal kernel is sound | **7/7** match the expected disposition |
| core capacity: band vs horizon | the band overclaim | width **constant** at 7d/30d/90d (= 2·1.96·RMSE) |

## Files

Edge half:
- `gen.py`   — synthetic labeled generator → `out/samples.jsonl` + `out/truth.csv`
- `plot.py`  — Fig-2-style plots + precision/recall/latency scorecard

Core half:
- `gen_seasonal.py` / `plot_seasonal.py` — hour-of-week baseline + labeled cases → `dispose_seasonal` proof
- `gen_capacity.py` — disk-fill points for the `dispose_capacity` band-overclaim demo
- the runner: `rust/causal-disposition/src/bin/disposition-backtest.rs` (`--kind seasonal|capacity`)

- `out/`     — generated artifacts (not source)

## Honest caveat

`anomaly-backtest` exercises the rolling z-score path plus (now) the saturation
gate and dispersion floors. The **seasonal** and **trend** signals still take a
caller-supplied baseline array that the CLI does not yet populate; proving those
(and the Phase-2 median/MAD + CUSUM upgrades, and the core seasonal/capacity NIF)
is tracked in `refactor-anomaly-engine-rigor` Phase 0 tasks.
