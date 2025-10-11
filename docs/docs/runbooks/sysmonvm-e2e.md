# Sysmon-VM End-to-End Validation (Mac host + Remote AMD64 Stack)

This runbook summarizes the steps we exercised locally while getting the new
`sysmon-vm` checker ready for testing. Use it as the checklist when you spin up
the Docker Compose stack on a remote Linux dev box (amd64) while keeping the
AlmaLinux VM + macOS host collectors running on the laptop.

## 1. Mac Laptop (Apple Silicon) – Host & VM Prep

1. **Bootstrap tooling**
   - `make sysmonvm-host-setup`
   - `make sysmonvm-fetch-image`
2. **Provision / start the AlmaLinux VM**
   - `make sysmonvm-vm-create` *(skip if the qcow2 already exists)*
   - `make sysmonvm-vm-start-daemon`
   - `make sysmonvm-vm-bootstrap`
3. **Build & install the sysmon-vm checker**
   - `make sysmonvm-build-checker`
   - `make sysmonvm-vm-install`
   - Confirm service: `scripts/sysmonvm/vm-ssh.sh -- sudo systemctl status serviceradar-sysmon-vm`
4. **Optional: prep load generator**
   - Inside the VM install stress tooling (already part of bootstrap, but double-check):\
     `scripts/sysmonvm/vm-ssh.sh -- sudo dnf -y install stress-ng`
5. **macOS host checker**
   - `sudo make sysmonvm-host-install`
   - Verify launchd unit if needed: `sudo launchctl list | grep com.serviceradar.sysmonvm`
6. **Keep the gRPC listener reachable**
   - The checker serves gRPC on the VM’s `0.0.0.0:50110`, forwarded to the host via user-mode networking.
   - Ensure macOS firewall allows inbound TCP/50110 so the remote Linux server can reach it (from the Linux box use `nc -vz <laptop-ip> 50110`).

## 2. Remote Linux Dev Server (amd64) – Docker Compose Stack

1. **Clone & checkout branch**
   ```bash
   git clone git@github.com:carverauto/serviceradar.git
   cd serviceradar
   git checkout feat/docker_cpu_monitoring   # or whichever branch you’re testing
   ```
2. **Ensure Docker daemon is up** (amd64 host with internet access to GHCR).
3. **Poller configuration**
   - We already added a `sysmon-vm` gRPC entry that defaults to `host.docker.internal:50110`.
   - For a remote server, **override that hostname** so the poller reaches back to the Mac. Two options:
     - Copy `docker/compose/poller.docker.json` to a temp file and replace the `details` value with `<laptop-ip>:50110`, then mount it via an override file.
     - Or use an environment override: create `docker/compose/poller.override.json` with just the modified check.
   - If you also run packaging installers outside of Compose, update `packaging/poller/config/poller.json` similarly (pointing to the Mac IP).
4. **Bring the stack up (amd64 images)**
   ```bash
   docker compose --profile testing up -d
   ```
   *(Compose v2 automatically reads `docker-compose.yml`; use `docker compose` syntax if available, otherwise `docker-compose` works as well.)*
5. **Validate services**
   - `docker compose ps`
   - `docker compose logs -f core poller agent`
6. **Confirm gRPC connectivity to the laptop**
   ```bash
   docker compose exec poller \
     grpcurl -plaintext <laptop-ip>:50110 grpc.health.v1.Health/Check
   ```
   You should see `{"status":"SERVING"}`.

## 3. End-to-End Test Flow

1. **Kick off load inside the AlmaLinux guest**
   ```bash
   scripts/sysmonvm/vm-ssh.sh -- \
     sudo stress-ng --cpu 4 --timeout 180 --metrics-brief
   ```
2. **Watch poller logs on the Linux server**
   ```bash
   docker compose logs -f poller | grep sysmon-vm
   ```
   Expect poll attempts and frequency payloads.
3. **Inspect core metrics**
   - Proton DB (from the Linux server):\
     `docker compose exec proton curl -sk -u default:$(cat /var/lib/proton/generated_password.txt) "https://localhost:8443/?database=default&query=SELECT%20*%20FROM%20cpu_metrics%20ORDER%20BY%20timestamp%20DESC%20LIMIT%205"`
   - Core API (if exposed) at `http://localhost:8090` -> `/pollers/.../sysmon/cpu`.
4. **Cross-check macOS checker**
   - `log show --predicate 'process == "serviceradar-sysmon-vm"' --last 5m`
   - Inspect `/var/log/serviceradar/sysmon-vm.log` and `.err.log` for IOReport or frequency sampling details.

## 4. Notes / Troubleshooting

- If `sysmon-vm` logs warn about missing security, provide TLS settings in `dist/sysmonvm/sysmon-vm.json` before copying into the VM.
- `host.docker.internal` is only defined for Docker Desktop; for a remote Docker host use the Mac’s routable IP.
- Network reachability: confirm both directions (Mac → Linux for OTLP, Linux → Mac for gRPC).
- The Compose stack expects GHCR credentials if the repo is private; log in via `docker login ghcr.io`.
- To tear everything down:
  - Linux server: `docker compose down -v`
  - Mac VM: `make sysmonvm-vm-destroy`
- Mac launchd: `sudo launchctl bootout system/com.serviceradar.sysmonvm`

## 5. Building Installable Artifacts

- **Signed macOS installer package**
  Ensure the Apple Timestamping Authority certificate is trusted before requesting timestamps:
  ```bash
  curl -L -o /tmp/AppleTimestampCA.cer https://www.apple.com/certificateauthority/AppleTimestampCA.cer
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/AppleTimestampCA.cer
  ```
  If your network prefers IPv6 and codesign cannot reach the TSA, set `PKG_TIMESTAMP_URL="http://17.32.213.161/ts01"` (the IPv4 endpoint) or rely on the script’s built-in fallback.
  ```bash
  PKG_SIGN_IDENTITY="Developer ID Installer: Carver Automation LLC (432Q4W72Q7)" \
  PKG_NOTARIZE_PROFILE="serviceradar-notary" \  # optional, if configured via `xcrun notarytool store-credentials`
  make sysmonvm-host-package
  ```
  The script emits both the tarball (`dist/sysmonvm/serviceradar-sysmonvm-host-macos.tar.gz`) and the signed `.pkg` (`dist/sysmonvm/serviceradar-sysmonvm-host-macos.pkg`). Skip notarization by omitting `PKG_NOTARIZE_PROFILE`. Use `SKIP_BUILD=1` when the binaries are already present in `dist/sysmonvm/mac-host/bin`.

- **Bazel target for release automation (local macOS executor)**
```bash
  PKG_APP_SIGN_IDENTITY="Developer ID Application: Carver Automation LLC (432Q4W72Q7)" \
  PKG_SIGN_IDENTITY="Developer ID Installer: Carver Automation LLC (432Q4W72Q7)" \
  PKG_DISABLE_TIMESTAMP=1 \  # skip TSA when offline; drop to get timestamped signatures
  #PKG_NOTARIZE_PROFILE="serviceradar-notary" \  # optional; requires stored notarytool credentials
  bazel build --config=darwin_pkg //packaging/sysmonvm_host:sysmonvm_host_pkg
```
The resulting `.pkg` is placed under `bazel-bin/packaging/sysmonvm_host/serviceradar-sysmonvm-host-macos.pkg` and is also exposed via the aggregate `//packaging:package_macos` filegroup for release workflows.

Keeping this file up to date ensures anyone can repeat the cross-host validation without re-reading the entire `cpu_plan.md`.
