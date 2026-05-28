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

Bumblebee scanning is split across two processes:

- `serviceradar-bumblebee-scan.service` runs as `root` on a timer. It resolves
  scan roots, invokes Bumblebee as a bounded one-shot scanner, sanitizes the
  output, and writes a spool file under `/var/lib/serviceradar/bumblebee/spool/`.
- `serviceradar-agent` remains non-root. It only reads the sanitized spool file
  and reports the result through the normal agent result path.

This split lets a Linux host scan all local users and `/root` without giving the
main agent broad filesystem privileges.

## Enabling On An Agent

The current package installs the ServiceRadar root scanner wrapper and systemd
timer. It expects the upstream Bumblebee CLI at `/usr/local/bin/bumblebee`; the
ServiceRadar build should pin and package that scanner binary before this is
enabled by default in production.

The packaged root scanner config is installed at
`/etc/serviceradar/bumblebee-scan.json`. It is disabled by default.

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

The main agent config has a separate `bumblebee` section that controls spool
reporting and catalog staging paths. In normal packages it points at:

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
