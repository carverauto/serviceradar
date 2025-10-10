# Host Frequency Sampler

`hostfreq` is an Objective‑C++ helper that snapshots macOS IOReport DVFS counters and emits
per-core / per-cluster CPU frequency estimates in MHz. The binary is intended to run on the
Apple Silicon host that is running the sysmon VM.

## Build

```
make sysmonvm-host-build
```

The build drops `hostfreq` into `dist/sysmonvm/mac-host/bin/`. Requirements:
- Apple clang (Xcode Command Line Tools) with C++20 support.
- Access to the private `libIOReport` shim that ships with macOS (available on Apple Silicon).

## Install as launchd service

```
sudo make sysmonvm-host-install
```

This installs `/usr/local/libexec/serviceradar/hostfreq`, registers the launchd unit
`com.serviceradar.hostfreq`, and starts it immediately. The service:
- Samples continuously with `--interval-ms 1000 --samples 0`
- Logs to `/var/log/serviceradar/hostfreq.log` and `.err.log`
- Exports `SERVICERADAR_HOSTFREQ_PATH` for downstream components
- Installs the macOS build of `serviceradar-sysmon-vm` plus a companion launchd unit
  (`com.serviceradar.sysmonvm`) that serves the gRPC checker using the shared config at
  `/usr/local/etc/serviceradar/sysmon-vm.json`

## Run

```
dist/sysmonvm/mac-host/bin/hostfreq --interval-ms 200 --samples 3
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
- The sysmon-vm checker on macOS automatically shells out to the installed helper when
  `SERVICERADAR_HOSTFREQ_PATH` is present, so no additional configuration is required
  beyond installing the launchd service.
