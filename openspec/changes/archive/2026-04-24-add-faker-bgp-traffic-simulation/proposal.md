# Change: Add BGP Traffic Simulation to ServiceRadar Faker

## Why
We need a deterministic way to generate realistic BMP/BGP activity in the demo environment so we can validate Arancini ingest, causal signal derivation, and state transitions (including outages) without depending on production routers.

The existing `serviceradar-faker` service already exists in demo flows and is the right place to host synthetic BGP scenarios instead of maintaining separate ad-hoc integration-only traffic generators.

## What Changes
- Add a BGP router simulation mode to `serviceradar-faker` that forms real BGP sessions between fake peers and exports BMP to the configured Arancini collector endpoint.
- Seed the simulator with a profile modeled after the provided FRR topology:
  - local ASN `401642`
  - internal peers in `10.0.2.2-10.0.2.13` and `2602:f678:0:ff::2-::13`
  - upstream peer examples `204.209.51.58` (AS10242) and `2605:8400:ff:142::` (AS10242)
  - advertised prefixes `23.138.124.0/24` and `2602:f678::/48`
- Emit scenario-driven route changes so demo users can trigger:
  - steady-state route advertisements
  - burst updates
  - peer session down/up events
  - randomized outage windows and recovery
- Configure BMP export destination (`host:port`) so all simulated routers stream actual BMP messages to Arancini.
- Do not implement direct faker-to-NATS BGP event publishing; all demo BGP data ingestion flows through BGP->BMP->Arancini.
- Integrate simulator controls into demo deployment configuration (Helm values and/or demo env config) so it is opt-in and reproducible.
- Reuse/port relevant topology and route generation ideas from `arancini/integration` GoBGP fixtures where practical, but keep runtime ownership in `serviceradar-faker`.

## Impact
- Affected specs:
  - `bgp-faker-simulation` (new)
  - `docker-compose-stack` (if local dev/demo overlays are updated)
  - `observability-signals` (indirect verification path via Arancini output)
- Affected code (expected):
  - `cmd/faker/*`
  - faker config schema/templates (`cmd/faker/config.json`, registry entries)
  - demo deployment wiring (Helm/demo values and/or compose overlays)
  - docs/runbooks for demo BGP simulation workflows
- Breaking changes:
  - None expected. Existing faker Armis emulation remains supported.
