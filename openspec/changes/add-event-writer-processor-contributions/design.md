## Context
ServiceRadar is moving add-ons and integrations into package-owned contracts. The UI
already has signal schema/display contracts so PowerDNS, Trivy, and future producers do
not need UI-specific branches. EventWriter still violates that direction: it hardcodes
producer modules, subject matchers, and batcher names in core.

That pattern does not scale. Third-party authors cannot add an integration unless core
ships a new BEAM module, and first-party integrations keep leaking into generic
pipeline code. At the same time, letting packages upload arbitrary Elixir modules,
SQL, JavaScript, or native code into EventWriter would be a security and operability
problem.

## Goals
- Make EventWriter routing and processor selection data-driven from approved package
  metadata.
- Let add-ons/integrations ship processor contributions through their package, import,
  and approval lifecycle.
- Persist processor and catalog contracts in core/CNPG at package install or
  registration time, because running add-ons may live on agents and are not directly
  reachable by core/web-ng.
- Support PowerDNS DNS Activity, Falco detections, Trivy vulnerability/compliance
  findings, Bumblebee scan activity/findings, endpoint inventory, and future security
  sidecars without producer-specific aliases in EventWriter.
- Keep transforms bounded, inspectable, testable, and safe to execute in core.
- Preserve gateway/agent-attested provenance and device correlation.
- Allow processor registry updates without requiring an application release for every
  new integration.

## Non-Goals
- Do not allow packages to load arbitrary Elixir modules into core.
- Do not allow packages to provide SQL, HTML, JavaScript, native code, or database DDL
  as an EventWriter processor.
- Do not let processor manifests decide tenancy, partition routing, RBAC, or trust
  boundaries.
- Do not require core/web-ng to call running add-ons to fetch processor definitions,
  catalogs, or mapping logic at event-processing time.
- Do not move EventWriter processing into add-ons.
- Do not require all old records to be backfilled or reprocessed.
- Do not remove the core platform processors for generic events/logs/OTEL/flows.

## Decisions

### D1: Processor contributions are package metadata
Add a `event_processors` or equivalent section to package metadata. Each contribution
declares:

- stable `id`, `version`, `producer_id`, and package version binding
- one or more NATS subject filters it owns
- payload kind, for example `ocsf_event`, `otel_log`, `json`, `scan_activity`,
  `security_finding`
- platform processor engine id
- destination family, for example `ocsf_events`, `logs`, `metrics`, or a platform
  finding table/view if already defined
- optional OCSF class/type metadata, including OCSF version
- schema/display references from the existing signal schema contract
- device-correlation mappings
- severity/action/status mapping rules
- promotion policy for log-to-event or event-to-alert input
- priority and conflict behavior for overlapping subject filters

The processor contribution is versioned with the package. Importing, installing, or
registering a new package version can stage a new processor version without changing
core code.

### D2: Approval controls activation
Processor contributions are inert until the package is approved. Approval records the
effective processor manifest after operator review and any platform validation. The
effective manifest is persisted in CNPG as a normalized contract owned by the package
version. A denied or revoked package disables its processor contributions. EventWriter
loads only approved processor contributions plus core platform defaults.

Core must never call a running add-on to ask for an EventWriter processor. Add-ons run
on agents and may only be reachable through agent-gateway/command bus paths; those paths
are for operational commands, not hot-path ingestion routing. The package/import path is
where the contract enters core.

### D3: EventWriter uses a registry snapshot
Introduce a processor registry read model that EventWriter can load at startup and
refresh after package approval/revocation. The registry snapshot contains normalized
routes and engine configuration, not package source files.

EventWriter SHALL build producer subscriptions, Broadway batchers, and processor
resolution from this snapshot. The pipeline must not contain producer-specific clauses
such as `get_processor(:pdns_ocsf)` or aliases for PowerDNS/Falco/Trivy.

Dynamic package-contributed JetStream consumers should use the same Broadway-backed
EventWriter path as the existing pipeline. Shared JetStream helper modules may keep
consumer creation/API utilities, but message consumption and back-pressure should remain
Broadway-owned rather than growing independent receive loops.

### D4: Core owns processor engines
Packages select from platform-owned engines. Initial engines:

- `ocsf_passthrough`: validate and store OCSF JSON payloads.
- `otel_log_passthrough`: validate and store OTEL-style logs.
- `json_to_ocsf`: map JSON fields into an OCSF event using declarative field paths,
  constants, templates, and enum maps.
- `security_finding`: normalize package payloads into OCSF Finding category events.
- `scan_activity`: normalize package payloads into OCSF Scan Activity events.
- `log_event_promotion`: store a log and optionally emit an event using bounded rules.

During migration only, a manifest may reference a platform-installed adapter id for
logic that cannot yet be expressed declaratively. The adapter registry is owned by core,
but EventWriter routing still comes from package metadata. New integrations should use
declarative engines.

### D5: Declarative transforms are bounded
Mapping rules may read fields from the incoming payload, set constants, apply severity
or enum maps, and render short string templates. They may not execute code, run SQL,
perform network I/O, allocate unbounded payloads, or mutate package/catalog state.

Validation enforces maximum manifest size, subject count, mapping count, field path
depth, template length, output payload size, and batch processing time. Invalid records
are dropped or stored as raw logs according to the contribution's error policy and must
emit processor telemetry.

### D6: Subjects remain platform-governed
Processor manifests declare requested subject filters, but the platform validates them
against allowed producer namespaces. A PowerDNS package can own `pdns.ocsf` or a
namespaced equivalent because the approved package owns that source. It cannot claim
internal health subjects, unrelated producer subjects, or cross-partition routes.

### D7: Device correlation is declarative and provenance-aware
Processor manifests may declare correlation candidates such as:

- `metadata.service_radar.agent_id`
- `metadata.service_radar.source_instance`
- `device.name`
- `src_endpoint.ip`
- `host.hostname`
- package-specific payload paths

The correlation engine uses these hints together with gateway/agent-attested metadata.
Manifest-provided fields are candidates, not authoritative identity.

### D8: First-party integrations become examples, not special cases
PowerDNS, Falco, Trivy, Bumblebee, and endpoint inventory should ship processor
contribution manifests with their packages. Documentation and SDK helpers should show
those as reference patterns. The EventWriter source tree should not grow new
producer-named processors for every integration.

### D9: Catalog and artifact refresh are generic package contributions
Catalog-style integrations, including Bumblebee, should declare catalog/artifact
contracts as package metadata instead of owning a core worker such as
`BumblebeeCatalogRefreshWorker`. The generic contract should cover:

- catalog source id, version, and schema
- fetch source and refresh cadence
- parser/validator engine id from platform-owned engines
- object-store staging destination
- snapshot promotion policy
- agent assignment metadata needed to retrieve the staged object through the
  agent-gateway artifact path

Core owns the generic catalog refresh worker and persistence model. A package can
contribute a catalog contract, but it cannot require core to call the add-on process to
resolve a catalog or to run package-supplied code.

### D10: SDKs expose typed contract builders
The add-on SDK in this repository and the external Go/Rust plugin SDKs should expose
idiomatic builders/validators for:

- signal schemas and display contracts
- EventWriter processor contributions
- catalog/artifact refresh contributions
- OCSF finding and scan activity mappings
- device-correlation hints

SDK APIs should produce package metadata that core can validate and persist. They should
not expose an API that implies the add-on will be called at runtime to process events.

## Risks / Trade-offs
- **Declarative mapping may not cover every case immediately.** Mitigate with a
  short-lived platform adapter escape hatch while moving common logic into reusable
  engines.
- **Subject conflicts can drop data or duplicate processing.** Mitigate with registry
  validation, priority rules, and explicit conflict errors during package approval.
- **Registry refresh can disrupt EventWriter.** Mitigate with versioned snapshots,
  atomic reload, and keeping the previous snapshot active when validation fails.
- **Third-party manifests could be abusive.** Mitigate with signing, approval,
  bounded DSL validation, payload limits, and telemetry on dropped records.
- **SDK drift can create invalid manifests.** Mitigate by sharing JSON Schema fixtures
  and validation examples across the in-repo add-on SDK and Go/Rust plugin SDKs.

## Migration Plan
1. Define the processor contribution schema and validation rules.
2. Build the registry read path and let EventWriter consume a static in-memory snapshot
   seeded with current core defaults.
3. Convert PowerDNS to a package-owned contribution using an `ocsf_passthrough` engine.
4. Convert Falco and Trivy to package-owned contributions using security finding and
   promotion engines.
5. Convert Bumblebee and endpoint inventory to scan activity/finding contributions.
6. Replace `BumblebeeCatalogRefreshWorker` with the generic package catalog/artifact
   refresh contract and worker.
7. Add typed add-on SDK, Go SDK, and Rust SDK helpers for processor/catalog
   contributions.
8. Remove producer-specific aliases, subject matchers, and batcher clauses from
   EventWriter.
9. Document processor contribution authoring for native add-ons, sidecars, and Wasm
   packages.

## Open Questions
- Should EventWriter reload registry snapshots through PubSub, Oban job scheduling, or
  supervisor restart?
- Which OCSF 1.9.0-dev finding/scan fields should be mandatory in the first migration
  for Bumblebee, Falco, Trivy, and endpoint inventory?
