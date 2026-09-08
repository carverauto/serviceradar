# Tasks

## 1. Stop residual config-push churn (root blocker)
- [ ] 1.1 Instrument `compute_version_hash` `version_payload` per-component (safe
      `:erlang.phash2`) and capture ≥2 consecutive real pushes for the proxmox
      agent to identify which component rotates per generation.
- [ ] 1.2 Make the rotating field deterministic (or strip it from the version
      hash, mirroring the `download_token_epoch` treatment).
- [ ] 1.3 Verify on demo: agent stops logging "Applied new config" every ~1s;
      proxmox check history shows no `module closed with context canceled`.
- [ ] 1.4 Keep the landed fixes: reconciler `params_equivalent?`, version-aware
      `push_config`, `download_token_epoch` removal.

## 2. Do not emit IP-less devices
- [ ] 2.1 In `discovery.go` `addGuestDiscoveries`/`addNodeDiscoveries`, only emit
      a `DiscoveredDevice` when `primaryIP(...)` is non-empty.
- [ ] 2.2 Confirm DIRE (`device_discovery_ingestor` `strong_enough?`) drops an
      address-less proxmox discovery rather than upserting an IP-less row.
- [ ] 2.3 Keep address-less guests in `details` (enrichment) for completeness.

## 3. Correct running/stopped status
- [ ] 3.1 Read `qmpstatus`/`status` (QEMU) and `status` (LXC) for the true
      runtime state; set `IsAvailable` + `Status` from it.
- [ ] 3.2 Unit test: stopped guest → `IsAvailable=false`, not emitted if no IP.

## 4. Deterministic node/guest identity (DIRE de-dup)
- [ ] 4.1 Emit one canonical `DeviceID` per guest and per node; stop emitting
      both name-based and MAC-based identities for the same guest.
- [ ] 4.2 Emit guest MAC(s) as device identifiers so DIRE merges the proxmox
      guest with the agent- and AWX-discovered host.
- [ ] 4.3 Verify on demo: each running guest/node is a single device;
      `sr-oracle-test`/`dusk01` collapse to one device across agent+proxmox+awx.

## 5. Verify end to end
- [ ] 5.1 Build plugin locally, hot-swap to agents, confirm a full cluster
      enumerates within the poll window (all running guests, each with an IP).
- [ ] 5.2 Confirm no IP-less proxmox rows; status matches Proxmox UI.
- [ ] 5.3 Add regression tests; land via PR; durable build+deploy.
