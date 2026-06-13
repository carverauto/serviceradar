## 1. Contract and Storage
- [ ] 1.1 Preserve `start_time_unix_nano` or equivalent reset anchor for cumulative metrics at storage.
- [x] 1.2 Store raw cumulative counter values without float64 precision loss.
- [ ] 1.3 Add schema validation requiring `temporality` for sum/histogram metric kinds.

## 2. Sysmon Counters
- [ ] 2.1 Add host boot/reset anchor to sysmon samples.
- [ ] 2.2 Tag network counters as monotonic cumulative sums with units and raw integer values.
- [ ] 2.3 Add disk IO counters as monotonic cumulative sums.

## 3. SNMP Counters
- [x] 3.1 Preserve raw counter values and PDU width from Counter32/Counter64.
- [ ] 3.2 Poll and attach `sysUpTime` and `ifCounterDiscontinuityTime` where available.
- [x] 3.3 Replace edge `calculateDelta` wrap-default behavior with reset-default logic.
- [ ] 3.4 Prefer 64-bit IF-MIB counters when available.

## 4. Consumer Normalization
- [x] 4.1 Implement a counter normalizer that computes rates/deltas from raw values and anchors.
- [x] 4.2 Drop or mark invalid reset/max-gap intervals instead of treating them as spikes.
- [x] 4.3 Feed anomaly detection rates for cumulative sums and raw values for gauges.

## 5. Tests and Benchmarks
- [x] 5.1 Add unit tests for reset, reboot, wrap, 64-bit decrease, max-gap, and precision cases.
- [ ] 5.2 Add synthetic anomaly tests proving cumulative counters do not create ramp false positives.
- [x] 5.3 Add benchmark coverage for counter normalization in the anomaly hot path.
