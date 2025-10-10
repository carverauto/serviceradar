# sysmon-vm Checker

The `sysmon-vm` checker is a lightweight gRPC service that exposes CPU metrics (including instantaneous frequency) from virtual machines or containerized environments where ServiceRadar’s standard Rust sysmon agent is not available.

## Features
- Collects per-core CPU usage via `github.com/shirou/gopsutil/v3/cpu`.
- Samples per-core frequency using `pkg/cpufreq`, which reads the Linux cpufreq sysfs interface and falls back to `/proc/cpuinfo`.
- Reports metrics through the standard `monitoring.AgentService` gRPC API so existing agent/poller/core pipelines ingest the data with no downstream changes.

## Configuration
Example configuration (`cmd/checkers/sysmon-vm/sysmon-vm.json.example`):

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
- `sample_interval`: Interval passed to `cpu.Percent` to calculate utilization; capped between 50 ms and 5 s.
- `security`: Optional mutual TLS settings matching other ServiceRadar components.

## Deployment Steps
1. Copy the binary into the target host (e.g., AlmaLinux VM) alongside the config file above.
2. Ensure `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` is readable inside the environment (run the container with `--privileged` or bind-mount `/sys` as needed).
3. Start the checker:\
   ```bash
   sudo /usr/local/bin/serviceradar-sysmon-vm --config /etc/serviceradar/checkers/sysmon-vm.json
   ```
4. From the ServiceRadar agent configuration, add a gRPC check named `sysmon-vm` that points to the checker’s address, for example:
   ```json
   {
     "name": "sysmon-vm",
     "type": "grpc",
     "details": "vm-host.example.com:50110"
   }
   ```
5. Restart the agent so the poller discovers the new checker; CPU frequency metrics will flow through the existing sysmon paths.

## Migration Notes
- Apply migration `pkg/db/migrations/00000000000006_cpu_frequency_column.up.sql` (and ensure fresh installs use the updated base migration) so the `cpu_metrics` stream includes the `frequency_hz` column.
- If you roll back, run the matching `.down.sql` to drop the column.
