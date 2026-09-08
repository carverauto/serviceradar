# Change: Verify Documentation Accuracy and Close Coverage Gaps

## Why

The `refactor-product-documentation` change cleaned up, reorganized, and re-themed the docs
site. It did not verify that what the docs *say* matches what the code *does*, nor whether
every shipped component is documented at all.

A component-by-component code scan — 8 Go binaries, 16 Rust crates, 11 Elixir apps, and
~25 Helm services — matched against the published docs found two classes of problem:

- **Accuracy drift.** Docs contradict the code in ways that will mislead users: the
  CNPG database name is wrong (`telemetry` vs `serviceradar`); `core-elx` is described as
  the control plane when the real control-plane OTP app is `serviceradar_core`; the
  architecture and data-pipeline diagrams route NetFlow through the Zen engine (it is
  not) and show `log-promotion` as a separate deployment (it is an in-process consumer);
  `otel.md` and `service-port-map.md` document an OTLP/HTTP port (4318) that the collector
  does not serve; `netflow.md` claims NetFlow v7 support and shows `flow-collector` config
  keys that will not deserialize; `syslog.md` recommends RELP, which is not a supported
  input; SNMP polling is described as running on "gateways" when it is an embedded agent
  service; the Helm chart version pins are ~50 releases stale (`1.2.20` vs `1.2.73`).
- **Stale published API spec.** `docs/openapi/index.yaml`, published at `/api/`, describes
  a legacy `/api/pollers/*` surface that no longer exists. The real `web-ng` API is
  `/api/query`, `/api/devices`, `/api/admin/*`, etc.
- **Coverage gaps.** Shipped, user-facing capabilities have no documentation at all:
  `rperf` network performance testing, the `serviceradar` CLI, the NATS-KV configuration
  system, RBAC roles and permissions, the agent configuration surface, and a web UI
  orientation page.

The goal is documentation that is **authoritative, accurate, concise, and complete** —
verified against the code, not just tidy.

## What Changes

- **Fix factual inaccuracies** across `architecture.md`, `data-pipeline.md`,
  `cnpg-monitoring.md`, `otel.md`, `service-port-map.md`, `netflow.md`, `syslog.md`,
  `snmp.md`, `bgp-routing.md`, `helm-configuration.md`, `network-sweeps.md`,
  `edge-model.md`, and `tls-security.md` — each fix grounded in a cited code reference.
- **Replace the stale OpenAPI spec.** Regenerate `docs/openapi/index.yaml` from the live
  `web-ng` admin spec (`/api/docs/v1/admin/openapi.json`) or replace it, and add a short
  `api-reference.md` covering authentication and the `/api/query` SRQL endpoint.
- **Add documentation for uncovered components:**
  - `rperf.md` — Network performance testing (checker + server, throughput/jitter/loss).
  - `cli-reference.md` — The `serviceradar` CLI and its subcommands.
  - `configuration-system.md` — The NATS-KV-via-`datasvc` configuration model.
  - `rbac-and-roles.md` — Roles, permissions, and custom role profiles.
  - `agent-configuration.md` — The agent config-file reference and check types (incl. MTR).
  - `web-ui-overview.md` — Navigating the web UI.
  - Document the BMP (arancini) ingest path and `datasvc` within existing pages, and add a
    `platform`-schema / data-model overview.
- **Trim bloat** so docs are concise: remove the BGP duplication and per-vendor configs
  bloating `netflow.md`, the duplicated rotation/custody guidance in `remote-access.md`,
  the duplicated checklists in `remote-access-rdp.md`, the sweep-tuning bulk in
  `helm-configuration.md`, and internal source-path / changelog narration where it leaks.
- **Explicitly do NOT publish** deprecated or wrong material: the checker-template KV
  seeding doc (the feature is disabled/deprecated in the chart), `hybrid-config-architecture.md`
  and `querying-service-config.md` (stale, Redis/ClickHouse-based), and the build/release
  maintainer docs (contributor material).

## Impact

- Affected specs: `product-documentation`
- Affected code:
  - `docs/docs/*.md` — accuracy edits, concision trims, ~6 new pages
  - `docs/openapi/index.yaml` — regenerated/replaced
  - `docs/sidebars.ts` — new pages added to the navigation
  - No application or runtime code changes
- Builds on `refactor-product-documentation`; lands in the same branch/PR.
