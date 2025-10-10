# Host Frequency Sampler

`hostfreq` is an Objective‑C++ helper that snapshots macOS IOReport DVFS counters and emits
per-core / per-cluster CPU frequency estimates in MHz. The binary is intended to run on the
Apple Silicon host that is running the sysmon VM.

## Build

```
cd tools/sysmonvm/hostfreq
make
```

Requirements:
- Apple clang (Xcode Command Line Tools) with C++20 support.
- Access to the private `libIOReport` shim that ships with macOS (available on Apple Silicon).

## Run

```
./hostfreq --interval-ms 200 --samples 3
```

- `--interval-ms` (default `200`): dwell time between IOReport samples.
- `--samples` (default `1`): number of snapshots to collect; each sample prints a JSON blob.

Example output:

```json
{
  "timestamp": "2025-10-10T17:52:54.553Z",
  "interval_request_ms": 150,
  "interval_actual_ms": 156.219291,
  "clusters": [
    { "name": "ECPU", "avg_mhz": 1594.77 },
    { "name": "PCPU", "avg_mhz": 2510.12 }
  ],
  "cores": [
    { "name": "ECPU0", "avg_mhz": 1572.97 },
    { "name": "PCPU0", "avg_mhz": 2810.20 }
  ]
}
```

## Integration Notes

- IOReport DVFS channels usually require elevated privileges. When wiring this into the OTEL
  collector, plan to run the helper via `sudo` (e.g., `exec` receiver with a dedicated sudoers
  entry) or a launchd agent that already runs with the correct entitlement.
- The program currently reports averages across active DVFS states; idle residency is ignored.
- Extend or wrap the JSON output as needed to forward metrics into ServiceRadar.
