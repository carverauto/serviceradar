## 1. Proposal
- [x] 1.1 Review existing agent, device inventory, datasvc object storage, Bumblebee, and CTI OpenSpec surfaces.
- [x] 1.2 Draft focused endpoint SBOM inventory proposal, design, tasks, and spec deltas.
- [x] 1.3 Validate with `openspec validate add-endpoint-sbom-inventory --strict`.
- [x] 1.4 Get proposal approval before implementation.

## 2. Agent And Collector
- [x] 2.1 Add endpoint inventory configuration structs, validation, profile delivery, and local override handling.
- [x] 2.2 Add a signed native add-on or scoped agent subcommand that collects Linux OS package inventory.
- [x] 2.3 Generate CycloneDX JSON with OS package components, OS metadata, collector provenance, and redaction metadata.
- [x] 2.4 Add bounded local spool handling, schema validation, size checks, and last-good artifact behavior.
- [x] 2.5 Add focused Go tests with dpkg, rpm, and apk fixture data.

## 3. Transport And Storage
- [x] 3.1 Define protobuf/API contracts for endpoint inventory scan metadata, normalized package summaries, and SBOM artifact references.
- [x] 3.2 Add durable object upload flow for raw SBOM artifacts through datasvc or an agent-gateway relay.
- [x] 3.3 Add Elixir migrations for endpoint inventory scan runs, SBOM artifacts, and normalized package/component rows in the `platform` schema.
- [x] 3.4 Add ingestion code that validates artifact hashes and replaces the current inventory view only after normalized rows commit.
- [ ] 3.5 Add retention cleanup for historical scans and raw artifacts.

## 4. Query And UI
- [x] 4.1 Add Ash resources/API reads for scan status, artifact metadata, and package rows.
- [ ] 4.2 Add SRQL fields or query support for package name, version, package manager, PURL, CPE, and current-vs-historical inventory state.
- [ ] 4.3 Add a device/asset detail surface showing latest scan status and installed package inventory.
- [ ] 4.4 Add operator controls for enabling sources, cadence, retention, and redaction.

## 5. Validation
- [ ] 5.1 Run focused Go tests for collector and spool validation.
- [x] 5.2 Run Elixir migration/resource tests for ingestion and current inventory replacement.
- [ ] 5.3 Run SRQL tests for endpoint package predicates and projections.
- [ ] 5.4 Run web-ng tests for inventory status and package UI.
- [ ] 5.5 Run OpenSpec validation and focused build/test commands before rollout.
