# Tasks

## 1. Add core-elx packaging directory

Create `packaging/core-elx/` with:

- `BUILD.bazel` — calls `serviceradar_package_from_config(name = "core-elx", config = PACKAGES["core-elx"])`
- `config/core-elx.env` — environment template (DATABASE_URL, NATS, cluster config, ports)
- `systemd/serviceradar-core-elx.service` — systemd unit using EnvironmentFile and the Mix release `start` command
- `scripts/postinstall.sh` — extracts tarball, sets permissions, runs `systemctl daemon-reload`
- `scripts/preremove.sh` — stops the service

Mirror the existing `packaging/web-ng/` structure exactly.

**Validate:** `ls packaging/core-elx/{BUILD.bazel,config/core-elx.env,systemd/serviceradar-core-elx.service,scripts/postinstall.sh,scripts/preremove.sh}`

## 2. Add agent-gateway packaging directory

Create `packaging/agent-gateway/` with the same structure as core-elx but for agent-gateway:

- `BUILD.bazel`
- `config/agent-gateway.env` — environment template (NATS, gRPC listen address, SPIFFE config)
- `systemd/serviceradar-agent-gateway.service`
- `scripts/postinstall.sh`
- `scripts/preremove.sh`

**Validate:** `ls packaging/agent-gateway/{BUILD.bazel,config/agent-gateway.env,systemd/serviceradar-agent-gateway.service,scripts/postinstall.sh,scripts/preremove.sh}`

## 3. Add both services to packages.bzl

Add `"core-elx"` and `"agent-gateway"` entries to the `PACKAGES` dict in `packaging/packages.bzl`. Each entry references:

- `//elixir/serviceradar_core_elx:release_tar` or `//elixir/serviceradar_agent_gateway:release_tar`
- The env config, systemd unit, and scripts from the packaging directories
- `deb_depends: ["systemd"]`, `rpm_requires: ["systemd"]`
- `conffiles` list for the env file

**Validate:** `bazel query //packaging/core-elx:all` and `bazel query //packaging/agent-gateway:all` show deb and rpm targets.

## 4. Verify release artifact inclusion

Build the full release artifacts and confirm the new packages appear:

```bash
bazel build //release:package_manifest
cat bazel-bin/release/package_manifest.txt | grep -E "core-elx|agent-gateway"
```

Both `.deb` and `.rpm` for each service should be listed.

## 5. Test package installation (manual)

On a clean Ubuntu/Debian VM:
- Install the `.deb` with `dpkg -i`
- Verify files are in place
- Verify `systemctl status serviceradar-core-elx` shows loaded (inactive)
- Edit env file, start service, verify it comes up

On a clean RHEL/Rocky VM:
- Install the `.rpm` with `rpm -i`
- Same verification steps

---

**Dependencies:** Tasks 1 and 2 can be done in parallel. Task 3 depends on both. Task 4 depends on 3. Task 5 is manual post-merge validation.
