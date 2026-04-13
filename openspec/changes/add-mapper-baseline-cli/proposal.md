# Change: Add Mapper Baseline CLI

## Why
Topology debugging is currently too indirect. When mapper evidence, ingestion, and God View disagree, operators have no supported way to run the discovery stack in isolation against a seed, controller, or SNMP target and compare the raw results with what lands in CNPG and the rendered graph.

## What Changes
- Add a standalone mapper baseline CLI built on the existing Go mapper/discovery library.
- Support explicit input modes for SNMP targets, UniFi controllers, and MikroTik controllers so engineers can run focused topology baselines without mutating scheduled jobs.
- Emit structured discovery artifacts and summary reports suitable for diffing against database rows and God View snapshots.
- Define a secure credential boundary: saved controller credentials MAY be exported for baseline runs only through ServiceRadar-managed Ash/Vault paths, and MUST NOT be decrypted directly from Postgres by the Go CLI.

## Impact
- Affected specs: `network-discovery`
- Affected code: `go/cmd/*`, `go/pkg/mapper/*`, and optionally Elixir-side credential export helpers in `elixir/serviceradar_core` / `elixir/web-ng`
