# Change: Report the drift level, arm the anchor on a mature window, exit on SIGTERM

## Why

Ten hours of add-on 0.3.10 on demo produced two false drift episodes on a
switch uplink whose rate was flat. The add-on had cold-started in the overnight
trough, captured its CUSUM anchor on the first `min_samples`, and read the
ordinary morning ramp as sustained upward drift. The verdict also reported a
"sustained level" that consumers reconstruct as `target + shift * scale`, which
overstated the real level by more than three times, because the anchor's scale
is refreshed every sample while the residuals behind the shift were measured
against earlier, smaller scales. Separately, sending the add-on SIGTERM left the
process alive with its RPC server gone: tonic's graceful drain waits for the
host's never-ending telemetry stream, the supervisor reports the add-on
unhealthy but only restarts on exit, and every upgrade ends in SIGKILL with no
chance to flush state.

## What Changes

- Anomaly add-on 0.3.11: the drift anchor is captured only once the rolling
  window holds `drift_anchor_min_samples` samples (default: the full window,
  never below `min_samples`); drift verdicts carry `drift_level`, the mean raw
  value over the run in metric units; `shutdown()` flushes the checkpoint.
- Rust add-on SDK: after SIGINT/SIGTERM the server drains for at most
  `GRACEFUL_EXIT_BOUND` (2 s) and then the process leaves, streams or not.
- Web: the drift finding chart draws `drift_level` as the sustained level and
  falls back to the sigma reconstruction only for older verdicts.

## Impact

- Affected specs: `anomaly-detection` (ADDED), `edge-architecture` (ADDED).
- Affected code: `rust/anomaly-addon` (engine, checkpoint, verdict, config),
  `rust/addon-sdk` (server), `addons/anomaly-addon` (schema, version),
  `elixir/web-ng` (device anomaly dialog), docs.
- Behaviour change: after a first start, drift detection waits for a full
  window (five hours at one sample a minute) instead of thirty samples. With
  checkpointing on, restarts no longer reset that clock.
