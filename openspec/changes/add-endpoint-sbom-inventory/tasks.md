## 1. Proposal
- [x] 1.1 Review existing agent, device inventory, datasvc object storage, Bumblebee, and CTI OpenSpec surfaces.
- [x] 1.2 Draft focused endpoint SBOM inventory proposal, design, tasks, and spec deltas.
- [x] 1.3 Validate with `openspec validate add-endpoint-sbom-inventory --strict`.
- [x] 1.4 Get proposal approval before implementation.
- [x] 1.5 Revise architecture for large-fleet scale: local cache, deterministic hashes, upload-on-change, and on-demand query path.

## 2. Agent And Collector
- [x] 2.1 Add endpoint inventory configuration structs, validation, profile delivery, and local override handling.
- [x] 2.2 Add a signed native add-on or scoped agent subcommand that collects Linux OS package inventory.
- [x] 2.3 Generate CycloneDX JSON with OS package components, OS metadata, collector provenance, and redaction metadata.
- [x] 2.4 Add bounded local spool handling, schema validation, size checks, and last-good artifact behavior.
- [x] 2.5 Add focused Go tests with dpkg, rpm, and apk fixture data.
- [ ] 2.6 Add deterministic package-set hashing over normalized sorted package identities.
- [ ] 2.7 Persist local last-known-good inventory cache with last uploaded package-set/artifact hashes.
- [ ] 2.8 Change scheduled scan reporting so unchanged inventories send lightweight status/hash summaries instead of full package/artifact uploads.
- [ ] 2.9 Add endpoint inventory on-demand command handling that evaluates bounded predicates against the local cache and optionally triggers an authorized fresh scan.

## 3. Transport And Storage
- [x] 3.1 Define protobuf/API contracts for endpoint inventory scan metadata, normalized package summaries, and SBOM artifact references.
- [x] 3.2 Add durable object upload flow for raw SBOM artifacts through datasvc or an agent-gateway relay.
- [x] 3.3 Add Elixir migrations for endpoint inventory scan runs, SBOM artifacts, and normalized package/component rows in the `platform` schema.
- [x] 3.4 Add ingestion code that validates artifact hashes and replaces the current inventory view only after normalized rows commit.
- [x] 3.5 Add retention cleanup for historical scans and raw artifacts.
- [ ] 3.6 Extend API/protobuf ingestion contracts with package-set hash, artifact hash, upload reason, unchanged scan status, and source summaries.
- [ ] 3.7 Make ingestion no-op unchanged package-set hashes for package-row replacement while still updating scan freshness metadata.
- [ ] 3.8 Make raw SBOM artifact storage content-addressed or hash-deduplicated and record reused artifact references.
- [ ] 3.9 Persist on-demand query command lifecycle/results using the existing agent command bus semantics.

## 4. Query And UI
- [x] 4.1 Add Ash resources/API reads for scan status, artifact metadata, and package rows.
- [x] 4.2 Add SRQL fields or query support for package name, version, package manager, PURL, CPE, and current-vs-historical inventory state.
- [ ] 4.3 Add a device/asset detail surface showing latest scan status and installed package inventory.
- [ ] 4.4 Add operator controls for enabling sources, cadence, retention, and redaction.
- [ ] 4.5 Add API/SRQL-visible freshness fields for package-set hash, last scan time, last changed scan time, and unchanged scan count.
- [ ] 4.6 Add an on-demand endpoint software query surface that targets a device, cohort, or SRQL-selected asset set and displays compact live results.

## 5. Validation
- [ ] 5.1 Run focused Go tests for collector and spool validation.
- [x] 5.2 Run Elixir migration/resource tests for ingestion and current inventory replacement.
- [x] 5.3 Run SRQL tests for endpoint package predicates and projections.
- [ ] 5.4 Run Go tests for hash-gated upload decisions, local cache fallback, and on-demand query command handling.
- [ ] 5.5 Run Elixir ingestion tests for unchanged package-set no-op behavior, artifact dedupe, and command result persistence.
- [ ] 5.6 Run web-ng tests for inventory status, freshness, package UI, and on-demand query UI.
- [ ] 5.7 Run OpenSpec validation and focused build/test commands before rollout.
