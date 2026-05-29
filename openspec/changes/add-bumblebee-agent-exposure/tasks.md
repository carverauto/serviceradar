## 1. Specification And Design
- [x] 1.1 Package Bumblebee through a root-owned scheduled scanner service while keeping `serviceradar-agent` non-root.
- [x] 1.2 Vendor and pin the upstream Bumblebee scanner implementation in ServiceRadar builds. The seeded catalog source is pinned to `v0.1.1+c24089804ee66ece4bec6f14638cb98985389cdb`.

## 2. Catalog Sync
- [x] 2.1 Add Elixir migrations for platform-scoped exposure catalog snapshots, catalog entries, device-linked postures, finding state, and sync audit state.
- [x] 2.2 Add Ash resources/actions for catalog snapshots and entries using project-owned modules around external fetch/parse logic.
- [x] 2.3 Enable AshPaperTrail on operator-managed catalog source and catalog snapshot promotion resources.
- [x] 2.4 Add an AshOban refresh job that fetches, validates, and promotes catalog snapshots without replacing the last-known-good snapshot on failure.
- [x] 2.5 Seed the initial catalog from the upstream Bumblebee `threat_intel` catalog.
- [x] 2.6 Materialize promoted catalog snapshots as immutable datasvc/NATS Object Storage artifacts with object key, size, SHA256, upstream revision, and catalog version metadata.
- [x] 2.7 Dispatch catalog assignment/update notifications through the agent config/control path so online agents can stage the assigned immutable snapshot.
- [x] 2.8 Record Bumblebee catalog refresh success and failure lifecycle events into `platform.ocsf_events`.

## 3. Agent Configuration
- [x] 3.1 Extend agent config protobufs and config compilers with opt-in Bumblebee profile settings.
- [x] 3.2 Add local Bumblebee config override and cache paths under the agent filesystem conventions.
- [x] 3.3 Add scanner-service root discovery for current user, all local user homes, `/root`, and explicit operator roots with bounded allow/deny policy.
- [x] 3.4 Package the pinned Bumblebee scanner service, systemd unit/timer, and non-root-readable sanitized output spool as an optional native capability bundle for Linux; macOS launchd packaging is follow-up.
- [x] 3.5 Keep the base `serviceradar-agent` package from installing or enabling Bumblebee root components by default.

## 4. Agent Execution And Ingest
- [x] 4.1 Run Bumblebee scans from the root-owned scanner service as bounded one-shot executions with configured profile, roots, ecosystems, max duration, and catalog snapshot.
- [x] 4.2 Write sanitized findings, scan summary, and coverage metadata to a root-owned spool path readable by the non-root agent.
- [x] 4.3 Have the agent parse the spool output, accept finding and scan summary records, and suppress full package inventory unless explicitly enabled.
- [x] 4.4 Report scan health, coverage, and findings through the existing agent push/gateway path with replay-safe IDs.
- [x] 4.11 Stage assigned catalog artifacts from ServiceRadar object storage, verify SHA256 before activation, and cache last-known-good catalog snapshots for offline scans.
- [x] 4.5 Resolve the reporting agent to its canonical device UID and persist posture/finding rows keyed by both device UID and agent ID.
- [x] 4.6 Add Bumblebee risk contribution derivation from active findings and catalog severity.
- [x] 4.7 Add or adapt the device risk contribution/reducer model so source ingestors update only source-specific contributions.
- [x] 4.8 Enable AshPaperTrail on composite risk policy/contribution resources where operator or reducer actions change auditable control-plane state.
- [x] 4.9 Feed the Bumblebee contribution into the device composite risk calculation while preserving source-specific posture provenance.
- [x] 4.10 Ensure Armis and other source updates cannot reduce the inventory-visible composite score below a higher active Bumblebee contribution.

## 5. UI, API, And Docs
- [x] 5.1 Add device detail API data for Bumblebee posture, catalog version, last scan time, coverage state, skipped roots, and active finding counts.
- [x] 5.2 Add a device detail Security/Supply Chain panel showing Bumblebee status, risk score, coverage, and active findings.
- [x] 5.3 Add docs for enabling the scanner service, choosing roots/profiles, catalog refresh behavior, coverage states, and privacy limits.

## 6. Verification
- [x] 6.1 Add unit tests for catalog parsing, promotion, and failure preservation.
- [x] 6.2 Add scanner service and agent tests with Bumblebee fixture NDJSON covering findings-only, scan-summary, coverage, and skipped-root handling.
- [x] 6.3 Add device posture association tests covering agent-to-device resolution and pending agent-only posture backfill.
- [ ] 6.4 Run targeted Go tests and `./scripts/elixir_quality.sh --project elixir/serviceradar_core`.
