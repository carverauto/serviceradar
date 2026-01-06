# sysmon-osx Checker

The `sysmon-osx` checker is a lightweight gRPC service that exposes CPU metrics (including instantaneous frequency) from macOS hosts where ServiceRadar's standard Rust sysmon agent is not available.

## Features
- Collects per-core CPU usage via `github.com/shirou/gopsutil/v3/cpu`.
- Samples per-core frequency using `pkg/cpufreq`, which reads the Linux cpufreq sysfs interface (falling back to `/proc/cpuinfo` and perf counters) and, on macOS, calls the embedded Objective-C++ IOReport collector.
- Reports metrics through the standard `monitoring.AgentService` gRPC API so existing agent/gateway/core pipelines ingest the data with no downstream changes.

## Configuration
Example configuration (`cmd/checkers/sysmon-osx/sysmon-osx.json.example`):

```json
{
  "listen_addr": "0.0.0.0:50110",
  "sample_interval": "250ms",
  "security": {
    "mode": "mtls",
    "role": "agent",
    "cert_dir": "/etc/serviceradar/certs"
  }
}
```

Key options:
- `listen_addr`: gRPC bind address for the checker.
- `sample_interval`: Interval passed to `cpu.Percent` to calculate utilization; capped between 50 ms and 5 s.
- `security`: Optional mutual TLS settings matching other ServiceRadar components.

## Deployment Steps
1. Copy the binary into the target host alongside the config file above.
2. Ensure `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` is readable inside the environment (on Linux; not needed on macOS).
3. Start the checker:\
   ```bash
   sudo /usr/local/bin/serviceradar-sysmon-osx --config /etc/serviceradar/checkers/sysmon-osx.json
```
4. From the ServiceRadar agent configuration, add a gRPC check named `sysmon-osx` that points to the checker's address, for example:
   ```json
   {
     "name": "sysmon-osx",
     "type": "grpc",
     "details": "osx-host.example.com:50110"
   }
   ```
5. Restart the agent so the gateway discovers the new checker; CPU frequency metrics will flow through the existing sysmon paths.

## macOS Host Deployment
- Build the macOS checker with `make sysmonosx-build-checker-darwin`; the binary is written to `dist/sysmonosx/mac-host/bin/serviceradar-sysmon-osx`.
- Install it with `sudo make sysmonosx-host-install`, which stages the checker under `/usr/local/libexec/serviceradar/serviceradar-sysmon-osx`, ensures `/usr/local/etc/serviceradar/sysmon-osx.json` exists, and loads the `com.serviceradar.sysmonosx` launchd unit.
- The embedded IOReport sampler runs inside the checker process, so no standalone `hostfreq` binary or environment variables are required.
- Logs land in `/var/log/serviceradar/sysmon-osx.log` and `.err.log`; IOReport permission issues are surfaced there as well.

## Migration Notes
- Apply migration `pkg/db/migrations/00000000000007_cpu_frequency_column.up.sql` (and ensure fresh installs use the updated base migration) so the `cpu_metrics` stream includes the `frequency_hz` column.
- If you roll back, run the matching `.down.sql` to drop the column.
