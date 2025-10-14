# CPU Frequency Monitoring Plan

## Goal
- Enable ServiceRadar to collect and visualize CPU frequency metrics from Docker containers running in an AlmaLinux 9 guest VM on Apple Silicon hosts.
- Capture complementary host-level CPU capacity metrics from macOS to evaluate resource headroom while the VM is running.

## Assumptions & Constraints
- Host hardware: Apple Silicon (M-series) running macOS 14+ with Homebrew available.
- Virtualization stack: QEMU 8.x using Hypervisor.framework (`-accel hvf`) and `-cpu host`.
- Guest OS: AlmaLinux 9.4+ ARM64 images (cloud or boot ISO).
- Container runtime: Docker CE inside AlmaLinux VM.
- ServiceRadar agent is Go-based; OpenTelemetry collector is already part of the deployment.
- Network access from guest and host to the central ServiceRadar endpoint (OTLP gRPC, default port 4317).
- CPU frequency exposed via Linux cpufreq sysfs; frequency values may reflect virtual CPU characteristics, not physical Apple Silicon clocks.
- macOS frequency data requires `sudo powermetrics`; automation must account for privilege requirements.

## Deliverables
- Reproducible automation (scripts or Make targets) to provision the AlmaLinux VM and install prerequisites.
- Dockerized ServiceRadar agent (or native install) with CPU frequency scraping enabled via Go library integration.
- OTEL configuration updates to emit `system.cpu.frequency` (Hz) per CPU core from guest containers.
- Companion macOS metrics collector emitting host CPU load, memory, and frequency proxy signals to ServiceRadar.
- Documentation and troubleshooting section specific to the nested virtualization path (macOS → QEMU → AlmaLinux → Docker).

## Work Breakdown Structure

### Phase 1 – Host Environment Preparation
- Verify Homebrew and install required tooling: `qemu`, `virt-install` (optional), `go` (>=1.22), `wget`, `sha256sum`.
- Ensure Hypervisor.framework is enabled and user has necessary privileges.
- Create working directory for VM artifacts (disk images, ISOs, cloud-init configs).
- Define configuration templates (YAML/JSON) to centralize VM parameters (CPU count, RAM, disk size, networking).
- Provide automation (`scripts/sysmonvm/host-setup.sh`, exposed as `make sysmonvm-host-setup`) that performs the prerequisite checks, installs tooling via Homebrew, and bootstraps the workspace at `dist/sysmonvm/`.

### Phase 2 – Acquire AlmaLinux ARM Images
- Download AlmaLinux 9.4/9.5 ARM64 cloud image (`AlmaLinux-9.x-GenericCloud-aarch64.qcow2`) for unattended provisioning.
- Optionally mirror boot ISO for manual install or recovery scenarios.
- Verify image integrity via published checksums and GPG signatures.
- Store metadata (image version, checksum, download URL) for reproducibility.
- Automate the download and checksum validation via `scripts/sysmonvm/fetch-image.sh` (exposed as `make sysmonvm-fetch-image`) using the workspace configuration.

### Phase 3 – VM Provisioning Automation
- Create a base QCOW2 disk (e.g., 40 GB) and configure QEMU launch scripts:
  - `-machine virt,accel=hvf`
  - `-cpu host`
  - `-smp` (default 4 vCPUs, parameterized)
  - `-m` (default 6 GB, parameterized)
  - `-drive file=<disk>,if=virtio`
  - `-netdev user,hostfwd=tcp::2222-:22` or bridged networking as needed
  - `-device virtio-net-pci`
- Integrate cloud-init or ignition configs to preinstall SSH keys, set hostname, and enable passwordless sudo for automation.
- Provide scripts/Make targets:
  - `make vm-create`
  - `make vm-start`
  - `make vm-destroy` (cleanup)
- Document how to access the VM console (serial, SPICE, VNC) for debugging.
- Implemented via `scripts/sysmonvm/vm-create.sh`, `scripts/sysmonvm/vm-start.sh`, and `scripts/sysmonvm/vm-destroy.sh` (exposed as `make sysmonvm-vm-create|start|destroy`).
- Cloud-init ISO creation currently uses `hdiutil` on macOS or `genisoimage` on Linux; ensure the appropriate tool is installed on developer hosts.
- Added convenience helpers for daemonized boots (`make sysmonvm-vm-start-daemon`) and quick SSH access (`make sysmonvm-vm-ssh`).
- QEMU start script now mounts the edk2 UEFI firmware (`edk2-aarch64-code.fd` + writable vars file) automatically; confirm the firmware package is present on the host before launching the VM.

### Phase 4 – Guest OS Bootstrap
- Update packages (`dnf update -y`) and install baseline tooling (`git`, `curl`, `vim`, `jq`).
- Install virtualization-friendly kernel modules if needed (`modprobe cpufreq-dt`, confirm loaded at boot).
- Install CPU frequency utilities (`sudo dnf install -y kernel-tools` for `cpupower`).
- Disable power-saving features that obscure frequency data during validation (`cpupower frequency-set -g performance`).
- Harden SSH access; ensure firewall rules allow outbound OTLP traffic.
- Automate the above via `scripts/sysmonvm/vm-bootstrap.sh` (exposed as `make sysmonvm-vm-bootstrap`), which performs the updates, installs required packages, and enables chronyd.

### Phase 5 – sysmon-vm Deployment
- Cross-compile the checker for Linux/arm64 (`scripts/sysmonvm/build-checker.sh` or `make sysmonvm-build-checker`) and stage artifacts under `dist/sysmonvm/bin/`.
- Copy the checker binary and config into the VM (`scripts/sysmonvm/vm-install-checker.sh` / `make sysmonvm-vm-install`), installing them to `/usr/local/bin` and `/etc/serviceradar/checkers` respectively.
- Optionally install the bundled systemd unit (`serviceradar-sysmon-vm.service`) to keep the checker running and restart on failure.
- Record operational runbook steps for updating the binary/config and recycling the service without rebooting the VM.

### Phase 6 – CPU Frequency Data Path Validation
- Confirm cpufreq sysfs presence on host VM: `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq`.
- Assess availability inside containers; if missing, document mitigations:
  - Run container privileged or with SYS_ADMIN capability.
  - Bind-mount `/sys/devices/system/cpu` read-only into the container.
- Use `/proc/cpuinfo` as fallback (less accurate).
- For nested virtualization on Apple Silicon (HVF), cpufreq files are typically absent; the checker now falls back to perf counters to estimate frequency. Ensure `kernel.perf_event_paranoid` allows access (bootstrap script sets it to `1`).
- Capture baseline metrics using `cpupower frequency-info` and `watch` on `scaling_cur_freq` for reference values.
- Record expected frequency ranges for different governors and workloads.

### Phase 7 – Go-Based Frequency Collector Implementation
- Evaluate `github.com/shirou/gopsutil/v3/cpu` support for ARM64 frequency on AlmaLinux in virtualized environments.
- Prototype frequency sampling in Go:
  - Implement abstraction that returns per-core frequency in Hz.
  - Handle environments where `cpu.FrequencyStat` is empty by falling back to direct sysfs reads.
- Integrate collector into ServiceRadar agent:
  - Add new metrics scraper module within `cmd/agent` or relevant package.
  - Expose configuration (sampling interval, enable/disable) via agent config file/env vars.
- Ensure agent reuses existing OTLP exporter pipeline.
- Add unit tests with fixtures mocking sysfs responses, and integration tests within AlmaLinux VM.
- Benchmark sampling overhead; target <5 ms per scrape for 8 cores.

### Phase 8 – OTEL Pipeline & Metrics Schema Updates
- Define metric name `system.cpu.frequency` (gauge, Hz) with attributes:
  - `cpu` (string e.g., `cpu0`)
  - `host_id` / `vm_id`
- Update OTEL collector config:
  - Add receiver entry for the new Go scraper or exec receiver fallback.
  - Tag metrics with resource attributes (service.name, environment, cluster).
- Update metric translation/transform rules and ensure compatibility with downstream storage (Timeplus Proton).
- Extend dashboards and alert templates to include CPU frequency visualization and thresholds.

### Phase 9 – Host macOS Monitoring Strategy
- Install OpenTelemetry Collector (`otelcol-contrib`) on macOS host.
- Embed the Objective-C++ IOReport sampler under `pkg/cpufreq` so the checker binary contains the macOS collector (no standalone helper to ship).
- Provide launchd packaging via `sudo make sysmonvm-host-install`; ensure logs land in `/var/log/serviceradar` and IOReport privileges are documented.
- Maintain Bazel coverage for the cgo build (`//pkg/cpufreq:cpufreq`) so macOS developers can run `bazel build --config=clang-tidy` for static analysis.
- Collect complementary metrics via `hostmetrics` receiver (CPU load, memory, temperature if available).
- Tag macOS metrics distinctly (resource attribute `service.name=macos-host-monitor`).
- Validate cross-origin metrics ingestion in ServiceRadar (host and guest metrics distinguished but correlated).

### Phase 10 – End-to-End Validation
- Load-test VM using `stress-ng --cpu N` and monitor frequency telemetry.
- Compare collected metrics against ground truth from `cpupower` (guest) and `powermetrics` (host) to ensure parity within ±5%.
- Simulate throttling (e.g., limit VM CPU via QEMU `-smp` or cgroup quotas) and verify telemetry reflects drops.
- Confirm metrics appear in ServiceRadar UI and Proton queries within acceptable latency (<15 s).
- Document test matrices (different vCPU counts, governors, container privilege modes).

### Phase 11 – Automation & CI Integration
- Extend existing repo scripts to spin up AlmaLinux VM in CI (optional, may require M-series runners).
- Add Go unit/integration tests to CI workflow; ensure new dependencies are mirrored in `go.mod`.
- Provide teardown scripts to clean VM images and docker artifacts.
- Capture sample data and include in reproducible fixtures for regression tests.

### Phase 12 – Documentation & Knowledge Transfer
- Produce runbook covering provisioning, monitoring setup, troubleshooting, and known limitations.
- Update ServiceRadar docs site with ARM CPU frequency guide.
- Record short demo (screenshots or asciinema) showing metrics dashboards.
- Open issues for follow-up items (e.g., support for additional guest OS versions).

## Risks & Mitigations
- **cpufreq not exposed in virtual CPU**: Investigate alternative telemetry (e.g., `scaling_boost_freq_khz`, virtio performance counters) or use QEMU guest agent enhancements.
- **Docker isolation hides sysfs**: Deploy agent as privileged or use hostPID namespace; validate security implications.
- **macOS privilege requirements**: Implement secure `sudoers` entries and audit logging; evaluate launchd daemon approach.
- **Metric accuracy**: Frequency reported may be capped or synthetic; document expectations and provide calibration steps.
- **Performance overhead**: Sampling powermetrics is cpu-intensive; tune interval or leverage caching.
- **Resource contention**: Ensure host metrics collection does not interfere with VM performance (benchmark).

## Open Questions
- Should the ServiceRadar agent expose aggregated metrics (min/max/avg) per scrape, or raw per-core gauges only?
- Is there a requirement to correlate guest frequency telemetry with host thermal or power data?
- Do we need to support non-Docker workloads inside AlmaLinux (e.g., podman, containerd) for the same telemetry path?
- What retention period and alert thresholds are expected for frequency anomalies?
- Is automated VM provisioning intended for developer laptops only, or also CI pipelines?

## Next Actions
1. Prototype Go-based frequency collector inside AlmaLinux VM to validate cpufreq availability.
2. Draft automation scripts (Makefile + shell) for AlmaLinux VM lifecycle on Apple Silicon.
3. Build minimal ServiceRadar dashboard to visualize guest and host CPU frequency side-by-side.
4. Answer open questions with stakeholders and adjust plan scope accordingly.

## Implementation Log
- **2025-10-10:** Added Go-based CPU frequency collector (`pkg/cpufreq`) leveraging gopsutil with sysfs fallback, wired into agent sysmon enrichment, and extended persistence and API layers to store `frequency_hz` alongside existing CPU metrics.
- **2025-10-10:** Replaced poller enrichment with dedicated `sysmon-vm` gRPC checker service, integrating CPU-frequency telemetry through the standard agent/core pipeline.

## Operational Checklist
- [ ] Apply migration `00000000000007_cpu_frequency_column.up.sql` (or redeploy using the updated base schema) so `cpu_metrics.frequency_hz` exists before rolling out the checker.
- [ ] Package and deploy the `sysmon-vm` checker binary/config with appropriate TLS materials.
- [ ] Register a new gRPC check (`name=sysmon-vm`) in the agent configuration/KV pointing to the checker instance.
- [ ] Confirm frequency data is present via the `/pollers/{id}/sysmon/cpu` API or Proton SQL queries using `frequency_hz`.
