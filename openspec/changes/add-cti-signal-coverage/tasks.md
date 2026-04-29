## 1. Proposal
- [x] 1.1 Review the existing OTX, NetFlow, observability, plugin, SRQL, and NetworkPolicy spec surfaces.
- [x] 1.2 Draft the CTI signal coverage proposal, design, tasks, and spec delta.
- [x] 1.3 Validate with `openspec validate add-cti-signal-coverage --strict`.
- [ ] 1.4 Get proposal approval before implementation.

## 2. Canonical CTI Inventory
- [ ] 2.1 Add or finalize `platform.threat_intel_observables` for all imported CTI observable types.
- [ ] 2.2 Preserve provider/source object metadata, confidence, severity, validity windows, collection identity, and raw artifact references.
- [ ] 2.3 Add type-specific normalized columns or projection tables for IP/CIDR, domain, URL, file hash, CVE, package, TLS fingerprint, and malware/campaign relationships.
- [ ] 2.4 Add lifecycle handling for stale, revoked, expired, and superseded observables.
- [ ] 2.5 Update OTX ingestion so non-IP observables are imported rather than counted only as unsupported.

## 3. DNS Telemetry
- [ ] 3.1 Define DNS observation schema for query name, normalized name, answer values, response code, client identity, resolver identity, timestamps, and metadata.
- [ ] 3.2 Add an opt-in ServiceRadar-managed internal DNS forwarding resolver deployment mode.
- [ ] 3.3 Add an integration path for existing DNS servers through logs, syslog, plugin collectors, or streaming exports.
- [ ] 3.4 Match domain and hostname observables against DNS queries and answers with exact and suffix semantics.
- [ ] 3.5 Add DNS CTI findings, SRQL fields, and UI drilldowns.

## 4. HTTP/TLS/WAF Telemetry
- [ ] 4.1 Define HTTP/TLS/WAF event schema for authority, URL, path, method, status, client/server IPs, SNI, TLS fingerprint, user agent, action, and policy metadata.
- [ ] 4.2 Add an opt-in Envoy deployment profile for access logging and WAF enforcement/observation.
- [ ] 4.3 Decide and document the first WAF engine integration point, such as Envoy external authorization, proxy-wasm, or a compatible rule engine.
- [ ] 4.4 Match URL, domain, hostname, TLS fingerprint, and HTTP metadata observables against HTTP/TLS/WAF events.
- [ ] 4.5 Surface hostile HTTP/WAF traffic in dashboard, topology, and asset views.

## 5. Endpoint Inventory And SBOM
- [ ] 5.1 Add agent collection for installed packages, OS release, language package manifests, listening services, and selected executable/file metadata.
- [ ] 5.2 Generate or collect SBOM documents from agents using an approved format such as CycloneDX or SPDX.
- [ ] 5.3 Store SBOM artifacts in NATS Object Store or durable object storage with normalized package rows in CNPG.
- [ ] 5.4 Match file hash, package, product, CPE, and CVE observables against endpoint inventory and SBOM data.
- [ ] 5.5 Add asset-level CTI/vulnerability context and affected-asset summaries.

## 6. SIEM And Edge Sightings
- [ ] 6.1 Define a generic CTI sighting contract for Wasm plugins and core-hosted integrations.
- [ ] 6.2 Add SDK helpers for emitting sightings and batches without custom JSON protocol code in every plugin.
- [ ] 6.3 Add one reference SIEM collector or fixture integration that emits normalized sightings.
- [ ] 6.4 Ensure each collector can be assigned to one or a bounded number of agents to avoid duplicate polling.
- [ ] 6.5 Add redacted health/status visibility for SIEM and edge CTI collectors.

## 7. Correlation, Alerts, And SRQL
- [ ] 7.1 Add deduplicated CTI sighting/finding tables linked to assets, flows, DNS events, HTTP/WAF events, endpoint inventory, and source observables.
- [ ] 7.2 Add SRQL predicates and projections for `threat:*`, `ioc:*`, `dns.threat:*`, `http.threat:*`, `asset.cve:*`, and related fields.
- [ ] 7.3 Add alert/rule hooks for new high-confidence sightings and repeated suspicious activity.
- [ ] 7.4 Add AGE graph relationships among observables, source objects, assets, flows, DNS answers, processes, packages, campaigns, and malware families.
- [ ] 7.5 Add bounded retrohunt jobs per observable type with resumable cursors and progress reporting.

## 8. UI And Operations
- [ ] 8.1 Distinguish imported observables from confirmed local sightings in the Threat Intel UI.
- [ ] 8.2 Add dashboards for CTI coverage by source: NetFlow, DNS, HTTP/WAF, endpoint/SBOM, vulnerability, and SIEM.
- [ ] 8.3 Add topology and NetFlow map overlays for CTI-matched hostile traffic.
- [ ] 8.4 Add asset-detail panels for matched CVEs, packages, file hashes, domains, and related CTI source objects.
- [ ] 8.5 Add operator controls for managed DNS, Envoy/WAF, SBOM collection, retention, redaction, and raw artifact archival.

## 9. Security, Retention, And Deployment
- [ ] 9.1 Encrypt provider, DNS, WAF, and SIEM credentials at rest and never return raw secrets to UI/API reads.
- [ ] 9.2 Add Kubernetes NetworkPolicy and Helm values for allowed CTI, DNS, WAF, and SIEM egress.
- [ ] 9.3 Add retention policies for DNS, HTTP/WAF, endpoint inventory, sightings, findings, and raw artifacts.
- [ ] 9.4 Add privacy redaction controls for DNS names, URLs, headers, and endpoint file paths.
- [ ] 9.5 Document deployment options and tradeoffs for managed DNS and Envoy/WAF.

## 10. Validation
- [ ] 10.1 Add migration/resource tests for observable inventory and sighting/finding deduplication.
- [ ] 10.2 Add matcher tests for IP/CIDR, domain, URL, hash, CVE/package, and TLS fingerprint observables.
- [ ] 10.3 Add agent/SBOM fixture tests with representative Linux package and executable data.
- [ ] 10.4 Add Envoy/WAF and DNS fixture ingestion tests.
- [ ] 10.5 Add SRQL tests for CTI predicates and projections.
- [ ] 10.6 Add LiveView tests for CTI coverage, settings, dashboards, and drilldowns.
- [ ] 10.7 Run focused Elixir, Go, Rust/SRQL, plugin build, OpenSpec, and demo smoke validation before rollout.
