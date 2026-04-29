# CTI Signal Coverage Design

## Context
Imported CTI only becomes useful when ServiceRadar has telemetry that can observe the same values. NetFlow can identify IP and CIDR matches, but it cannot observe domain-only, URL-only, file-hash, package, CVE, malware-family, or HTTP-policy indicators. The design adds a signal coverage layer that preserves the full CTI inventory and projects observables into source-specific matchers.

## Goals
- Preserve all imported CTI observables with provider/source metadata.
- Match observables against the telemetry source that can actually observe them.
- Keep high-cardinality matching out of synchronous page renders and hot ingest paths.
- Expose CTI evidence through SRQL, findings, alerts, dashboard summaries, topology overlays, asset detail, and NetFlow/DNS/HTTP/WAF views.
- Support edge-local collection for customer DNS, WAF, SIEM, and endpoint data where core cannot directly reach the source.

## Non-Goals
- Inline full-feed matching inside LiveView requests.
- Send all customer DNS or HTTP data to third-party CTI providers.
- Make ServiceRadar the mandatory DNS resolver or ingress controller for every deployment.

## Data Model
Use separate layers:

- `threat_intel_observables`: canonical provider inventory for every imported observable, including type, value, provider, source object, confidence, severity, validity, and metadata.
- Match projection tables: source-specific normalized views such as IP/CIDR, domain, URL, file hash, package/CVE, TLS fingerprint, and WAF rule context.
- Sightings/findings: deduplicated evidence records that link an observable to an asset, flow, DNS event, HTTP request, endpoint file/process/package, vulnerability, or SIEM event over a time window.
- Raw artifact store: optional NATS Object Store snapshots for original feed pages, DNS/WAF batches, SBOM documents, or SIEM exports when audit/replay is enabled.

## Telemetry Sources
- NetFlow/IPFIX/sFlow: IP, CIDR, port, protocol, ASN, GeoIP, and flow direction matching.
- Managed DNS: ServiceRadar-operated forwarding resolver or log collector for query name, answer, client, response code, TTL, and resolver metadata.
- HTTP/TLS/WAF: Envoy access logs and WAF decision logs for URL, authority, path, SNI, TLS fingerprint, user agent, response status, and action.
- Endpoint inventory: agent-collected packages, processes, listening sockets, file metadata, and SBOM documents.
- Vulnerability inventory: CVE observations from SBOM/package scans, external scanners, or imported SIEM/vulnerability feeds.
- SIEM sightings: edge Wasm collectors that normalize customer-local SIEM events into the same sighting contract.

## Matching Model
Each observable type owns a matcher:

- IP/CIDR: existing NetFlow cache and retrohunt path, optimized with observed-IP prefiltering.
- Domain/hostname: DNS query and answer matcher with suffix/exact-mode semantics.
- URL: HTTP access log and WAF request matcher with canonicalization rules.
- File hash: endpoint file/process/SBOM matcher.
- CVE/package: asset package inventory and SBOM matcher.
- TLS fingerprint: HTTP/TLS flow metadata matcher when available.

Matchers run as bounded jobs, maintain high-water marks, and write deduplicated sightings. UI and SRQL read the sighting/finding tables, not the full feed directly.

## Deployment Model
ServiceRadar-managed DNS and WAF are opt-in:

- DNS can run as an internal forwarding resolver, a sidecar/DaemonSet log collector, or an integration against an existing resolver.
- Envoy/WAF can run at the edge proxy, as a gateway component, or as a Kubernetes ingress path where the deployment already accepts that traffic path.
- Edge SIEM collectors run as signed Wasm plugins assigned to specific agents to avoid duplicate feed pressure and to reach customer-local systems.

## Security And Privacy
- CTI provider credentials, SIEM credentials, and WAF/DNS integration credentials must use encrypted settings or deployment secrets.
- Edge collector egress must be allowlisted.
- DNS and HTTP telemetry can contain sensitive names and paths; retention, redaction, and raw archival must be configurable.
- UI must clearly distinguish imported observables from confirmed local sightings.

## Performance
- Feed-scale observable matching must be asynchronous and indexed.
- Matchers should work from observed-value sets or recent high-water slices before joining against the full CTI inventory.
- Continuous aggregates or summary tables should support dashboard cards and top-N views.
- Long-running retrohunts must be chunked by time and observable type with resumable cursors.
