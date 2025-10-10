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

## Host Preparation (Phase 1)
- Run `make sysmonvm-host-setup` from the repository root to install QEMU and related tooling (via Homebrew on macOS) and to scaffold the VM workspace under `dist/sysmonvm`.
- The script seeds `config.yaml` in that workspace using `tools/sysmonvm/config.example.yaml`; review the template and update CPU, memory, disk, and port values before provisioning the VM.
- On Linux hosts the script currently prints manual install guidance—extend `scripts/sysmonvm/host-setup.sh` once a target distribution matrix is agreed upon.

## Host Preparation (Phase 2)
- Download the AlmaLinux Generic Cloud image listed in `dist/sysmonvm/config.yaml` by running `make sysmonvm-fetch-image` (or the underlying `scripts/sysmonvm/fetch-image.sh`).
- After the download completes, compute the SHA-256 checksum with `shasum -a 256 dist/sysmonvm/images/<filename>` and update `config.yaml` so future runs can verify integrity. The script warns when the checksum field is still `sha256:REPLACE_ME`.
- Use `make sysmonvm-fetch-image WORKSPACE=/custom/path` if you keep VM artifacts outside of `dist/sysmonvm`.

## VM Provisioning (Phase 3)
- Run `make sysmonvm-vm-create` to build a qcow2 overlay disk and generate the cloud-init seed ISO based on `dist/sysmonvm/config.yaml`. Pass `--force` (via `WORKSPACE` or direct script use) to recreate the assets.
- Boot the guest with `make sysmonvm-vm-start`; the helper launches `qemu-system-aarch64` headless with port forwards for SSH (`localhost:<ssh_port> → 22`) and any extra ports defined under `networking.forwarded_ports`.
- Use `make sysmonvm-vm-start-daemon` to run the VM in the background—serial output is captured under `dist/sysmonvm/logs/`, and the QEMU monitor socket is published in `dist/sysmonvm/metadata/`.
- When you need to reclaim space or rebuild from scratch, run `make sysmonvm-vm-destroy` (use `--yes` to skip the confirmation prompt).
- While running in headless mode, press `Ctrl+A` followed by `X` to exit QEMU cleanly. Add `--no-headless` to `sysmonvm-vm-start` if you prefer a graphical console.
- On macOS the scripts rely on `hdiutil` to build the cloud-init ISO; on Linux install `genisoimage` (or another `mkisofs` provider) before running `sysmonvm-vm-create`.
- Ensure the QEMU edk2 firmware blobs are installed (Homebrew `qemu` already ships `edk2-aarch64-code.fd` and `edk2-arm-vars.fd`). The start script copies the vars template into `dist/sysmonvm/metadata/` automatically.
- `make sysmonvm-vm-ssh` opens an SSH session to the guest using the configured user and forwarded port. Provide `ARGS="command"` to run a non-interactive command (e.g., `make sysmonvm-vm-ssh ARGS="uptime"`).

## Guest Bootstrap (Phase 4)
- With the VM running, execute `make sysmonvm-vm-bootstrap` to apply OS updates, install baseline packages (git, curl, jq, kernel-tools, etc.), and enable chronyd.
- Cross-compile the checker with `make sysmonvm-build-checker`; the binary is written to `dist/sysmonvm/bin/serviceradar-sysmon-vm`.
- Deploy the checker into the guest using `make sysmonvm-vm-install`. By default this copies the config (`dist/sysmonvm/sysmon-vm.json`), installs the binary under `/usr/local/bin`, and enables the accompanying systemd unit. Set `SERVICE=0` to skip unit installation.
- Verify the service via `make sysmonvm-vm-ssh ARGS="sudo systemctl status serviceradar-sysmon-vm"` or inspect logs with `journalctl -u serviceradar-sysmon-vm`.
- In environments where the cpufreq interface is missing (e.g., QEMU on Apple Silicon using Hypervisor.framework), the checker samples hardware performance counters to compute an effective frequency. If the kernel forbids perf events, ensure `kernel.perf_event_paranoid` is ≤1 (handled automatically by `make sysmonvm-vm-bootstrap`).

## macOS Host Frequency Helper
- Build the host-side collector with `make sysmonvm-host-build`; the binary is deposited at `dist/sysmonvm/mac-host/bin/hostfreq`.
- Install the launchd service with `sudo make sysmonvm-host-install`. This stages the binary under `/usr/local/libexec/serviceradar/hostfreq`, registers `com.serviceradar.hostfreq`, and starts continuous sampling (output logged to `/var/log/serviceradar`).
- You can still run ad-hoc samples locally (e.g., `dist/sysmonvm/mac-host/bin/hostfreq --interval-ms 200 --samples 5`) to verify IOReport access and privilege configuration.
- The helper must run with privileges that allow IOReport access (typically root or a launchd agent with the appropriate entitlement). The install script exports `SERVICERADAR_HOSTFREQ_PATH` so other components locate the binary reliably.
- The same install script deploys a macOS build of `serviceradar-sysmon-vm` as `com.serviceradar.sysmonvm`; the checker uses `SERVICERADAR_HOSTFREQ_PATH` to call the helper and merges host MHz data into the gRPC payload. Linux/perf paths remain the fallback for environments where cpufreq/perf are available.

Refer back to `cpu_plan.md` for Phase 5+ (metric verification, sysmon-vm telemetry plumbing, dashboard work).

## Migration Notes
- Apply migration `pkg/db/migrations/00000000000006_cpu_frequency_column.up.sql` (and ensure fresh installs use the updated base migration) so the `cpu_metrics` stream includes the `frequency_hz` column.
- If you roll back, run the matching `.down.sql` to drop the column.
