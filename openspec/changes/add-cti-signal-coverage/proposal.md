# Change: Add CTI Signal Coverage

## Why
The AlienVault OTX work gives ServiceRadar a path to import external CTI, but IP/CIDR matching against NetFlow only uses a small part of the intelligence. Most CTI feeds include domains, URLs, file hashes, CVEs, malware relationships, campaigns, and infrastructure metadata. To make those IOCs operationally useful, ServiceRadar needs first-party telemetry surfaces that can observe those values and a correlation layer that can turn matches into findings, alerts, SRQL fields, and graph context.

## What Changes
- Add a canonical CTI observable inventory that stores all imported observables, not only NetFlow-matchable IP/CIDR indicators.
- Add match projections for each observable family so expensive feed-scale matching is performed through indexed, source-specific tables and background jobs.
- Add managed DNS telemetry options, including an internal forwarding resolver mode, DNS log ingestion, and CTI domain/hostname matching.
- Add HTTP/TLS/WAF telemetry through Envoy so URL, host, SNI, JA3/JA4, method, status, and policy decision data can be correlated with CTI.
- Add an endpoint software and SBOM inventory path from agents so package, executable, file hash, and CVE observables can be matched against assets.
- Add optional SIEM/source connectors that can run as Wasm plugins at the edge and emit sightings into the same CTI match contract.
- Extend SRQL, alerting, dashboard, NetFlow, topology, and asset views to expose CTI context across flow, DNS, HTTP, WAF, endpoint, and vulnerability evidence.
- Keep CTI credentials and secrets encrypted at rest, and enforce explicit egress allowlists for edge collectors and managed DNS/WAF components.

## Impact
- Affected specs: threat-intel-signal-coverage, observability-signals, observability-netflow, srql, wasm-plugin-system, plugin-sdk-go, build-web-ui, kubernetes-network-policy
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/observability/**`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/**`
  - `rust/srql/**`
  - `go/cmd/agent/**`
  - `go/cmd/wasm-plugins/**`
  - `go/pkg/**`
  - `helm/serviceradar/**`
  - `k8s/**`

## Non-Goals
- Replace the current OTX importer or NetFlow IP/CIDR matching path.
- Require every deployment to run ServiceRadar-managed DNS or WAF components.
- Build a full SIEM replacement in this slice; SIEM integrations should feed sightings and observables into the common CTI model.
- Store raw packet payloads by default.

## Dependencies
- The `add-alienvault-otx-integration` change provides the first CTI feed source and initial IP/CIDR matching path.
- Agent and gateway config delivery must support opt-in deployment of managed DNS, Envoy/WAF, and endpoint inventory collectors.
- Kubernetes deployments need NetworkPolicy and secret-management updates before managed egress components are enabled by default.
