---
id: bumblebee
title: Bumblebee Exposure Scanning
sidebar_label: Bumblebee Exposure Scanning
---

# Bumblebee Exposure Scanning

ServiceRadar can use [Bumblebee](https://github.com/perplexityai/bumblebee) to
scan developer endpoints for package and tool exposure matches against a reviewed
threat-intel catalog. The integration is designed for findings-first incident
response: ServiceRadar stores scan posture, active findings, coverage metadata,
catalog provenance, and risk contribution data. It does not upload full local
package inventory by default.

## Architecture

Bumblebee scanning is an optional native capability split across two processes:

- `serviceradar-bumblebee-scan.service` runs as `root` on a timer. It resolves
  scan roots, invokes the vendored Bumblebee scanner implementation as a
  bounded one-shot scan, sanitizes the output, and writes a spool file under
  `/var/lib/serviceradar/bumblebee/spool/`.
- `serviceradar-agent` remains non-root. It only reads the sanitized spool file
  and reports the result through the normal agent result path.

This split lets a Linux host scan all local users and `/root` without giving the
main agent broad filesystem privileges.

## Optional Deployment

The base `serviceradar-agent` package does not install, configure, or start the
root-owned Bumblebee scanner helper. This keeps the default RPM/deb installer
minimal for operations groups that do not want privileged local exposure
scanning on every agent host.

Bumblebee should be deployed as an explicit native capability add-on through
Edge Ops feature-set deployment. On Linux this add-on is packaged as
`serviceradar-bumblebee-scan`; it carries the root helper,
`serviceradar-bumblebee-scan.service`, `serviceradar-bumblebee-scan.timer`, the
scanner config, and the `/var/lib/serviceradar/bumblebee` state directory
ownership/permissions. The package reloads systemd but does not enable or start
the timer by default. The main agent remains the same binary and only reports
Bumblebee posture when its optional `bumblebee` config is enabled.

The helper vendors the pinned Bumblebee scanner implementation and runs it
in-process; there is no separate upstream Bumblebee CLI runtime dependency and
no shell-out to another scanner binary.

## Enabling On An Agent

When the native capability add-on is installed, its root scanner config lives at
`/etc/serviceradar/bumblebee-scan.json`. It should be disabled until Edge Ops or
a local operator explicitly enables it.

Install the Linux add-on only on hosts approved for privileged local scanning:

```bash
sudo apt install serviceradar-bumblebee-scan
# or
sudo dnf install serviceradar-bumblebee-scan
```

Do not assign Bumblebee scanning to the in-cluster `k8s-agent` pod. Bumblebee needs
a host that can own `/var/lib/serviceradar/bumblebee`, run the scanner timer, and
read the intended local roots. Target workstation, server, or developer endpoint
agents instead.

Set the scanner config to enabled and use the reporting agent ID:

```json
{
  "enabled": true,
  "agent_id": "default-agent",
  "catalog_path": "/var/lib/serviceradar/bumblebee/catalog/current",
  "spool_dir": "/var/lib/serviceradar/bumblebee/spool",
  "tmp_dir": "/var/lib/serviceradar/bumblebee/tmp",
  "include_home_roots": true,
  "include_root": true
}
```

Then enable and start the timer:

```bash
sudo systemctl enable --now serviceradar-bumblebee-scan.timer
```

The main agent config has a separate optional `bumblebee` section that controls
spool reporting and catalog staging paths. When enabled, it normally points at:

- `/var/lib/serviceradar/bumblebee/spool/latest.json`
- `/var/lib/serviceradar/bumblebee/catalog/current`
- `/var/lib/serviceradar/bumblebee/tmp`

## Root Selection

Do not rely on Bumblebee's process home directory for fleet coverage. The
ServiceRadar scanner wrapper resolves roots before invoking Bumblebee.

- `include_home_roots: true` scans local user home directories found in
  `/etc/passwd`.
- `include_root: true` includes `/root`.
- `explicit_roots` adds operator-selected roots.
- `exclude_roots` removes roots from the final set.

Unreadable or excluded roots are reported as skipped roots. Partial coverage is
not treated as a clean scan.

## Catalog Refresh

Core owns catalog refresh. A coordinator-only Oban worker can fetch the pinned
upstream Bumblebee `threat_intel` catalog bundle, normalize entries, store a
candidate snapshot in CNPG, upload the normalized artifact to ServiceRadar object
storage, and promote the snapshot only after validation succeeds.

Seeded source defaults:

- Repository: `https://github.com/perplexityai/bumblebee`
- Tag: `v0.1.1`
- Commit: `c24089804ee66ece4bec6f14638cb98985389cdb`
- Path: `threat_intel/*.json`

The catalog refresh scheduler is disabled unless
`BUMBLEBEE_CATALOG_REFRESH_ENABLED=true` or the matching application config is
enabled. Agents never fetch raw upstream catalog URLs during normal operation.
They receive a catalog assignment through the ServiceRadar config/control path,
download the immutable object-store artifact, verify the SHA256, and then
activate the local catalog. If staging fails, the last-known-good local catalog
stays in place.

## Device UI And Risk

Device details show a Security/Supply Chain panel when Bumblebee posture exists.
The panel includes scan state, source agent, last successful scan, catalog
snapshot, coverage state, skipped roots, active finding counts, highest severity,
and the source-specific Bumblebee risk contribution.

Bumblebee writes its own contribution into the composite device risk model.
Other sources, such as Armis, update only their own contribution rows, so a later
lower Armis score does not overwrite a higher active Bumblebee contribution in
the `/devices` inventory risk score.

## Coverage States

- `complete`: all selected roots scanned successfully.
- `partial`: at least one selected root was skipped or not covered.
- `failed`: the scanner failed before producing reliable coverage.
- `not_scanned`: no usable completed scan is available.

Treat `partial`, `failed`, and `not_scanned` as unknown exposure posture, not as
proof that the device is clean.

## Privacy Limits

Bumblebee findings can include package names, versions, ecosystem data, evidence
summaries, and local path context. ServiceRadar stores bounded findings and scan
metadata, not full package inventory by default. Review local policy before
enabling scanning on shared workstations or hosts with sensitive source paths.
