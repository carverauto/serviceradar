## 1. Processor Contribution Contract
- [ ] 1.1 Define the package metadata schema for EventWriter processor contributions.
- [ ] 1.2 Add validation for ids, versions, subject filters, processor engine ids,
  destinations, OCSF metadata, mapping rules, limits, and conflict policy.
- [ ] 1.3 Extend package import/approval flows so processor contributions are staged,
  reviewed, approved, denied, and revoked with the package version.
- [ ] 1.4 Add SDK/docs helpers so add-on and sidecar authors can ship processor
  contributions without touching core code.

## 2. Registry And EventWriter Routing
- [ ] 2.1 Implement a processor registry read model that returns approved processor
  contributions plus core platform defaults as a versioned snapshot.
- [ ] 2.2 Refactor EventWriter config to build streams/subscriptions from the registry
  snapshot instead of static producer-specific defaults.
- [ ] 2.3 Refactor EventWriter pipeline routing to resolve batchers through registry
  entries and processor engine ids instead of producer-specific `get_processor/1`
  clauses.
- [ ] 2.4 Add conflict handling for overlapping subjects and keep the previous snapshot
  active when a registry refresh fails validation.

## 3. Processor Engines
- [ ] 3.1 Implement `ocsf_passthrough` for package-emitted OCSF events such as
  PowerDNS DNS Activity.
- [ ] 3.2 Implement `otel_log_passthrough` for package-emitted OTEL-style logs.
- [ ] 3.3 Implement `json_to_ocsf` with bounded field paths, constants, enum maps, and
  string templates.
- [ ] 3.4 Implement `security_finding` and `scan_activity` engines for OCSF 1.9
  security/finding/scan signals.
- [ ] 3.5 Implement processor telemetry for accepted, dropped, malformed, and promoted
  records.

## 4. First-Party Migration
- [ ] 4.1 Move PowerDNS out of EventWriter aliases/routes and into its add-on package
  processor contribution.
- [ ] 4.2 Move Falco sidecar ingestion to a package-owned processor contribution.
- [ ] 4.3 Move Trivy report ingestion to a package-owned processor contribution.
- [ ] 4.4 Move Bumblebee scan activity/findings to package-owned processor
  contributions.
- [ ] 4.5 Move endpoint inventory findings/events to package-owned processor
  contributions.
- [ ] 4.6 Delete producer-specific EventWriter routing and processor aliases once the
  registry-backed packages are active.

## 5. Validation
- [ ] 5.1 Add unit tests for processor manifest validation and subject conflict
  detection.
- [ ] 5.2 Add EventWriter routing tests that prove PowerDNS/Falco/Trivy/Bumblebee are
  resolved from registry entries, not hardcoded pipeline clauses.
- [ ] 5.3 Add integration tests for malformed manifests and malformed records.
- [ ] 5.4 Run `openspec validate add-event-writer-processor-contributions --strict`.
- [ ] 5.5 Run targeted Elixir quality/tests for EventWriter and package approval code.
