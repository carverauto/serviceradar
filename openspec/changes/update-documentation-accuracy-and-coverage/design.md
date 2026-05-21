## Context

A six-part parallel code audit scanned every ServiceRadar component and matched it against
the published docs (`docs/docs/*.md`). This document records the coverage matrix, the
verified accuracy issues, and the decisions about what to fix, add, trim, and deliberately
not publish. Every accuracy fix in `tasks.md` cites the code reference that proves it.

This change is content-only — no application code changes.

## Coverage Matrix (audit result)

| Area | Component | Doc | Status |
|---|---|---|---|
| Edge | agent, sweep, sysmon, SNMP poll, mapper | edge-model, network-sweeps, sysmon-profiles, snmp, discovery | accuracy fixes needed |
| Edge | agent config file surface | — | **MISSING** |
| Edge | MTR checks, agent check types | — | **MISSING** |
| Edge | agent-updater, release rollout | agent-release-management | accurate |
| Ingest | log-collector (syslog+OTLP, unified) | syslog, otel | partial / stale |
| Ingest | log-collector-tcp (TCP syslog) | — | **MISSING** |
| Ingest | trapd (SNMP traps) | snmp | partial |
| Ingest | flow-collector (NetFlow/IPFIX/sFlow) | netflow | config keys wrong |
| Ingest | bmp-collector / arancini (BMP) | bgp-routing | **STALE** ("not available") |
| Core | serviceradar_core (control plane) | architecture | **mislabeled as core-elx** |
| Core | agent-gateway | architecture, edge-model | partial |
| Core | datasvc | — | **MISSING** |
| Pipeline | zen, db-event-writer, log-promotion | data-pipeline, architecture, rule-builder | diagram/claims wrong |
| Data | CNPG, `platform` schema | cnpg-monitoring, database-bootstrap | wrong DB name; no schema overview |
| Query | SRQL (tutorial/reference/cookbook) | srql-* | accurate |
| UI | web UI overview / navigation | — | **MISSING** |
| UI | RBAC roles & permissions | — | **MISSING** |
| API | HTTP/JSON API | openapi/index.yaml | **STALE (legacy poller API)** |
| Deploy | Helm | helm-configuration | stale version pins, sweep-heavy |
| Config | NATS-KV config system | — | **MISSING** |
| Tooling | `serviceradar` CLI | — | **MISSING** |
| Perf | rperf (checker + server) | — | **MISSING** |

## Decisions

### Decision: Every accuracy fix must cite a code reference
The audit produced a code citation for each inaccuracy. `tasks.md` carries those
citations. A fix is not "done" until the doc matches the cited code.

### Decision: Replace the stale OpenAPI spec with the live admin spec
`docs/openapi/index.yaml` is a Swagger 2.0 doc describing `/api/pollers/*` — a surface that
no longer exists. `web-ng` serves a live, generated admin spec at
`/api/docs/v1/admin/openapi.json`. The published spec is replaced with an export of the
live spec, and a short `api-reference.md` page is added covering API authentication
(session vs. API credentials) and the `/api/query` SRQL endpoint.
- *Alternative considered:* hand-maintaining `index.yaml`. Rejected — it already drifted
  badly; the generated spec is the source of truth.

### Decision: Do not publish deprecated or wrong material
- **Checker-template KV seeding** (`checker-template-registration.md`, unpublished): the
  Helm chart sets `checkerTemplates.enabled: false` with the comment "deprecated; leave
  disabled." This doc is **not** published. Checker setup is documented through the current
  "Settings → Networks" UI workflow instead.
- **`hybrid-config-architecture.md`** and **`querying-service-config.md`** (unpublished):
  stale and wrong — they describe Redis/ClickHouse, not the real NATS-KV/CNPG system. They
  do **not** seed published docs; the configuration page is written fresh from
  `rust/config-bootstrap/` and `datasvc`.
- **`BUILD_VERSIONING.md`, `RELEASE_PUBLISHING.md`, `GHCR_PUBLISHING.md`** (unpublished):
  contributor/maintainer material — they stay unpublished.

### Decision: New pages vs. sections
New standalone pages (real, distinct topics with no home today):
`rperf.md`, `cli-reference.md`, `configuration-system.md`, `rbac-and-roles.md`,
`agent-configuration.md`, `web-ui-overview.md`, `api-reference.md`.
Covered as sections in existing pages (smaller scope): BMP ingest → `bgp-routing.md`;
`datasvc` → `data-pipeline.md`; the `platform` schema / data-model overview →
`database-bootstrap.md` (or a short `data-model.md` if it grows); MTR and agent check
types → `agent-configuration.md`.

### Decision: Resolve the control-plane naming
`architecture.md` calls `core-elx` "the Elixir control plane." In code,
`serviceradar_core_elx` is a thin app (camera/desktop media ingress) and `serviceradar_core`
is the real control plane; the Helm `serviceradar-core` deployment runs the
`serviceradar-core-elx` image but the release node is `serviceradar_core`. The docs adopt
one consistent name — **`core`** — for the control-plane service in prose, and note the
OTP app name where it matters, rather than implying `core-elx` is a separate control plane.

### Decision: Concision is in scope
"Concise" is an explicit goal. The change trims verified bloat: the BGP section duplicated
between `netflow.md` and `bgp-routing.md`, the per-vendor flow-export configs in
`netflow.md`, the twice-stated rotation/custody guidance in `remote-access.md`, the
duplicated checklists in `remote-access-rdp.md`, and the sweep-tuning bulk in
`helm-configuration.md` (which duplicates `network-sweeps.md` / `syn-scanner-tuning.md`).

## Risks / Trade-offs

- **Audit currency.** The audit reflects code at scan time; fast-moving areas (BMP/arancini
  wiring, the Elixir vs. Go `EventWriter`) may shift. → Re-verify each cited reference at
  edit time; where behavior is genuinely ambiguous, document the observable contract, not
  internals.
- **New-page volume.** Six-plus new pages is a large writing effort. → Pages are scoped
  tight and operator-focused; SDK/dev-portal material is not duplicated.
- **OpenAPI export.** The live admin spec must be obtainable from a running `web-ng`. → If
  it cannot be exported during this change, the stale `index.yaml` is replaced with a
  minimal accurate spec plus the `api-reference.md` prose, and a follow-up captures the
  full export.
- **Build integrity.** New pages and links must keep `onBrokenLinks: throw` green. →
  `npm run build` is the gate.

## Open Questions

- Is BMP (arancini) data joined into `bgp_routing_info`, or only landed in the
  `ARANCINI_CAUSAL` stream? The BMP section wording depends on the answer — resolve by
  reading the consumer wiring at edit time.
- Is the deployed persistence consumer the Go `db-event-writer` or the Elixir Broadway
  `EventWriter`? Docs should name the authoritative one (`db-event-writer` appears to be
  the deployed default; `EVENT_WRITER_ENABLED` defaults to `false`).
- Can the live `web-ng` admin OpenAPI spec be exported in this change, or does that need a
  running instance the author provides?
