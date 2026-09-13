## 1. Anomaly add-on 0.3.11

- [x] 1.1 `drift_anchor_min_samples` (engine, config, schema): anchor capture and max-age re-anchor gate on it; default `window_size`, clamped to `[min_samples, window_size]`.
- [x] 1.2 `drift_level`: sum of raw values over the pending run and the open episode (state + checkpoint fields); `CusumDrift.level`; payload `drift_level`.
- [x] 1.3 `shutdown()` writes the final checkpoint.
- [x] 1.4 Tests: level equals the mean raw value over the run; no drift before the anchor is armed on a cold start; payload carries `drift_level`; existing lifecycle tests pin the old arming threshold explicitly.

## 2. Add-on SDK

- [x] 2.1 `serve_until_signal`: run the server, on signal call `shutdown()`, ask tonic to drain, and return after at most `GRACEFUL_EXIT_BOUND`.
- [x] 2.2 Integration test: SIGTERM with an open telemetry stream returns within the bound.

## 3. Web

- [x] 3.1 Drift context reads `drift_level`; the sustained-level line uses it and falls back to `target + shift * scale`.
- [x] 3.2 Test: a row with `drift_level` draws that level.

## 4. Verification on demo

- [ ] 4.1 After the roll: a SIGTERM to the add-on ends the process within seconds and the agent restarts it; the restart re-warms (first health report shows restored series).
- [ ] 4.2 No drift episode opens on the switch uplink's diurnal ramp after a cold start.
