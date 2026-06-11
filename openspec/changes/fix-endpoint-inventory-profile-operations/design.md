## Context
Endpoint inventory currently depends on several pieces lining up: an add-on package must be approved, an agent must be eligible, an add-on assignment must be materialized, the agent config must include the assignment, the collector must run on the endpoint, the agent must validate/upload the spool payload, and the control plane must ingest that payload against the canonical device.

The current operator experience hides too much of that chain. A profile query such as `in:devices` does not clearly show which devices resolved to enrolled agents, which agents were eligible for the endpoint inventory add-on, or which assignments/config deliveries are active. On the device page, a low package count is shown as data instead of as a possible partial scan.

One observed failure is concrete and small: `AddonProfile` action implementations access `context[:actor]`, but Ash passes an `Ash.Resource.Actions.Implementation.Context` struct that does not implement `Access`. The reconcile action therefore raises and terminates the LiveView process.

## Goals
- Make endpoint inventory assignment a one-path workflow for normal operators: select Endpoint Inventory, target devices with SRQL, preview, enable, reconcile.
- Make every stage from profile match to package rows inspectable.
- Make low or empty package counts actionable by exposing generic scanner diagnostics.
- Put endpoint package inventory in a dedicated device details Software tab.
- Add a generic vulnerability advisory contract and central matching path for endpoint software data.
- Keep agents and add-ons inside the existing boundary: agents talk to agent-gateway, not web-ng or JetStream directly.

## Non-Goals
- Do not redesign the endpoint inventory storage model from `add-endpoint-sbom-inventory`.
- Do not add direct add-on to web-ng or add-on to JetStream access.
- Do not run vulnerability feed matching on endpoint agents.
- Do not make OSV ScaLibr a core dependency.
- Do not put provider-specific feed parsers or normalizers in core.
- Do not make force-fresh fleet scans the default operator workflow.
- Do not require a new add-on-specific UI for every future native add-on.

## Design Decisions

### Profile targeting is the primary path
Endpoint inventory SHALL be configured through add-on profiles first. A simple setup should need only:
- profile name
- target SRQL query, defaulting to `in:devices`
- enable/disable state
- optional cadence or config preset

Manual per-agent assignment remains available only as an advanced override, with provenance shown anywhere assignment state is displayed.

### Reconcile output is a deployment report
Profile preview and reconcile results SHALL be structured as a deployment report:
- matched rows from SRQL
- devices with no enrolled agent
- resolved agents
- agents skipped for platform/version/capability/package-policy reasons
- assignments created, updated, retained, or skipped by manual override
- config delivery state when known
- last collector status when known

This report is the bridge between "my query matched 13 devices" and "these agents will actually run endpoint inventory."

### Collection diagnostics are first-class data
Endpoint inventory needs a scanner diagnostic status model, not just `package_count`. A scan result with two packages can be healthy on a minimal container host, partial because rpm/dpkg/apk were unavailable, or failed because permissions blocked `/var/lib/dpkg/status`.

The collector and ingest path SHALL preserve:
- enabled scanner plugins or package sources as diagnostic entries
- detected package managers and databases
- per-diagnostic package/finding counts
- per-diagnostic errors and skipped reasons
- scan duration and timeout state
- max package/output truncation state
- collector version and config hash

### Device details owns endpoint software presentation
Endpoint package inventory belongs in a device details Software tab. That tab should show summary cards, freshness, source coverage, package manager breakdown, package search/filtering, and clear empty/partial states.

### Current SBOM path remains the input contract
Endpoint inventory currently produces CycloneDX JSON from package manager collection and stores raw SBOM artifacts through the durable object path when content changes. That remains the contract for downstream matching. Agents and add-ons provide inventory/SBOM evidence; vulnerability intelligence add-ons/plugins provide already-normalized advisory batches. The control plane owns contract validation, source/snapshot metadata, matching, risk scoring, and OCSF Vulnerability Finding emission.

### Vulnerability intelligence is source-owned
Vulnerability feed implementations SHALL live outside core as native add-ons or Wasm plugins. A producer owns:
- provider-specific configuration and credentials
- download scheduling and retry policy
- schema validation and integrity checks
- archive/pointer handling
- translation from native feed shape into the ServiceRadar advisory batch contract

For example, a CISA KEV producer validates the CISA JSON Schema inside that producer; a VulnCheck producer resolves pointer JSON and verifies declared SHA-256 values inside that producer. Core SHALL NOT contain CISA, NVD, VulnCheck, OSV ScaLibr, or other provider-specific parser branches.

Core SHALL expose a generic source registry, normalized advisory storage, snapshot provenance metadata, source enablement for matching, last status/error, and bounded ingestion errors. Adding a new feed should require only a producer package and fixtures that emit the advisory contract; it SHALL NOT require core code changes.

### Threat intelligence producers are independent
Threat intelligence feed download, validation, and normalization SHOULD be packaged as independent producer add-ons or plugins, not as part of endpoint inventory. Endpoint inventory and scanner add-ons submit observed software/SBOM evidence. Intelligence producers submit normalized advisory batches. The central matcher joins those two streams after ingestion.

Native add-ons and Wasm plugins are both valid packaging models for vulnerability and threat intelligence producers. The decision should be based on runtime fit, not object-store privilege. Agents, add-ons, and Wasm plugins SHALL NOT talk directly to JetStream or the object store. Durable artifact staging, object download, object upload, checksum verification handoff, and catalog/object lookup SHALL go through APIs brokered by the agent-gateway and exposed through the host/add-on SDKs.

Large feeds such as NVD mirrors, VulnCheck backups, pointer JSON, and zip archives can run as Wasm plugins when the Wasm host ABI exposes the needed gateway-backed capabilities: credential lookup, bounded HTTP/download support, streaming or chunked object writes, object metadata, digest validation, and resumable scheduling semantics. Native add-ons remain acceptable for producers that need OS/runtime capabilities outside the Wasm sandbox, but native packaging SHALL NOT be required merely to stage or retrieve durable artifacts.

The target architecture is runtime-neutral for feed producers: a producer that can run inside the Wasm sandbox should be able to download, validate, normalize, stage, and submit advisory batches through the same logical gateway-mediated contracts as a native add-on. Object-store access is never the differentiator because neither runtime receives direct JetStream/object-store credentials.

The native add-on SDK and the Go/Rust Wasm plugin SDKs SHOULD expose first-class advisory-feed helper types/builders and gateway-mediated artifact helper APIs so producers do not hand-roll JSON or bypass ServiceRadar's object boundary. SDK support is only for constructing/submitting the generic contract and staging producer artifacts through agent-gateway; provider-specific CISA, NVD, VulnCheck, OSV, or future feed logic remains inside the producer package.

### Producer schedules are package-owned contracts
Recurring feed pulls SHALL be declared by the producer package, not hard-coded in
core. A Wasm plugin or native add-on that needs periodic execution declares a
schedule contract in its manifest/SDK metadata. That contract describes:
- stable schedule id and display labels
- the action or command to invoke
- default cadence, minimum and maximum cadence, optional cron support, and jitter
- required operator settings and credential references
- payload template and redaction/display hints
- whether the command is assignment-scoped, package-scoped, or target-query scoped

When a package is installed or approved, core SHALL persist the declared schedule
contract as platform metadata and expose it to web-ng. The settings UI SHALL render
schedule controls from that generic contract, so adding a CISA, NVD, VulnCheck,
OSV, or future feed producer does not require a new LiveView or provider branch.

Operator schedule state SHALL be stored separately from the package contract:
enabled state, cadence/cron, target assignment or SRQL policy, credential refs,
last run, next due time, last status, and last error. Package upgrades may add or
retire schedule contracts, but operator schedule choices remain explicit platform
state.

Core-elx owns the AshOban scheduling loop. Web-ng may edit schedule settings and
trigger a run-now action, but it SHALL NOT become the global scheduler. The due
worker loads enabled producer schedules, resolves the selected plugin/add-on
assignment or target policy, builds the package-declared command payload, and
dispatches over the existing agent commandbus. Wasm producers use the generic
`plugin.run_action` command. Native add-on producers use the generic
`addon.run_command` command, which travels through agent-gateway to the selected
agent before the agent invokes the local add-on gRPC `RunCommand` RPC. Core and
web-ng SHALL NOT reach out to add-ons directly.

The schedule dispatcher records command ids, status, and errors against the
generic producer schedule. Advisory feed ingestion remains independent: successful
producer runs emit normalized advisory batches through plugin result/telemetry or
native add-on telemetry, and those batches are accepted by the same advisory
contract regardless of how the run was scheduled.

### Matching is central and explainable
The endpoint side owns observed package coordinates: PURL, candidate CPEs where available, package manager, name, version, architecture, scan id, and SBOM artifact hash. The intelligence producer owns advisory coordinates, CVSS/severity, KEV metadata, and source-native version range translation into generic match semantics. The matcher owns package/SBOM coordinate comparison, confidence, evidence, risk projection, and resulting findings.

Each match result SHALL keep evidence explaining why the package matched: feed provider, CVE/advisory id, coordinate type, version range, package identity, scan id, and confidence. Findings are device-scoped and SHALL appear in the Software tab alongside the package inventory rather than requiring operators to pivot to raw events.

### Scanner integrations extract useful evidence
Trivy and Falco are scanner/runtime signal producers, so the ingestion path must extract product-specific facts and map them to OCSF rather than simply preserving their raw JSON.

Trivy ingestion SHALL extract scan identity, target scope, resource identity, image/package coordinates, CVE/advisory ids, installed/fixed versions, severity, CVSS where available, vulnerability references, compliance/policy checks, and scanner metadata. The system SHALL emit OCSF Scan Activity for the report lifecycle and the appropriate OCSF Finding class for each security outcome. CVE-backed Trivy results SHALL also be compatible with the endpoint vulnerability risk model so device and image findings can be queried together while retaining their different scopes.

Falco ingestion SHALL extract rule name, rule source, priority/severity, output fields, process/container/kubernetes metadata, host identity, user/process/file/network evidence, and runbook/reference metadata where available. Falco alerts primarily become OCSF Detection Findings and SHALL preserve enough resource evidence to answer what process/container/host triggered the alert.

Both integrations SHALL preserve raw payload references for audit/replay, but dashboards, SRQL, alerts, and device details SHALL consume normalized fields. Dedupe keys must include producer, source event/report identity, affected resource, finding identity, and normalized time bucket or source revision as appropriate, so repeated reports do not create duplicate active findings.

### Security page links to findings, not just raw events
The Security page must be an investigation surface, not only a feed of OCSF parent events. A Trivy `VulnerabilityReport for ReplicaSet/...: 22 findings (CRITICAL)` event is useful as report lifecycle context, but it is not the actionable finding list. The UI SHALL provide a drill-down from that summary into the 22 concrete vulnerabilities with CVE id, package, installed version, fixed version, severity, CVSS where available, image/workload/resource scope, namespace, references, and remediation metadata.

Likewise, Falco rows SHALL drill into the rule/detection details: rule name, priority, source, output fields, host, Kubernetes workload, container, process, command line, user, file/network evidence, and runbook/reference fields where available. The raw Event Details page remains available as audit context, but it SHALL NOT be the only destination for a scanner finding link.

For aggregate report producers, ingestion may store one parent Scan Activity/report event plus many child findings. The UI and SRQL/query layer must expose both levels and preserve the relation between them.

### Security page and dashboard have different jobs
The `/security` page is a tactical operator workspace. It should answer "what needs action now?" with prioritized active findings, scanner health, affected devices/workloads/images/packages, remediation details, assignment/status workflows, and fast pivots into device/software/event context.

The authored `/dashboards/security-findings` dashboard is a customizable posture and analytics surface. It should answer "what is our trend and exposure posture?" with editable panels for severity distribution, finding class/source mix, KEV/exploit exposure, scan coverage, stale scanner data, top affected namespaces/images/devices, MTTR, and historical trend charts.

Both surfaces SHALL use the same normalized OCSF/query data and may link to each other, but they SHALL NOT be duplicates. The dashboard should be safe to customize and share; `/security` should provide the opinionated investigation workflow.

Summary cards on both surfaces should be drill-down controls, not static counters. A card for critical vulnerabilities, stale Trivy scans, Falco detections, KEV exposure, top affected namespace, or failed endpoint inventory coverage SHALL open a scoped detail view, apply a filter, or navigate to the relevant finding/workload/device cohort. Non-clickable cards are acceptable only for purely decorative or explanatory content, which should be rare on these operator surfaces.

### Event display contracts are source-owned
Scanner integrations SHALL ship display contracts for Event Viewer and security drill-down surfaces. The contract describes the fields to extract, labels, grouping, severity/status presentation, child finding collection paths, resource pivots, remediation fields, and raw payload fallback behavior. Web-ng should render the contract generically rather than hard-coding Trivy or Falco JSON shapes in the event page.

For the observed Trivy payload shape, the display contract needs to expose at minimum:
- report summary: `report_kind`, `resource`, `namespace`, `cluster_id`, scanner name/version, artifact repository/tag, worst severity, severity counts, update timestamp
- resource correlation: owner kind/name/uid, resource kind/name/namespace, container name, image repository/tag, Kubernetes UID
- child vulnerabilities: `vulnerabilityID`, `severity`, `title`, `installedVersion`, `fixedVersion`, links/references, package/artifact identity when available
- remediation prioritization: fixed version presence, critical/high first ordering, KEV/exploit enrichment when available, and stale report age

The event page can still show the raw source event, but it must first show an actionable report summary and child finding table when the display contract identifies one.

### Scanner add-ons are interchangeable
Endpoint inventory and security scanners SHALL plug into ServiceRadar through scanner-agnostic add-on contracts. Core, agent, gateway, ingest, database, UI, and SRQL code SHALL depend on generic contracts:
- scan activity metadata
- inventory/SBOM artifacts
- scanner plugin/source diagnostics
- OCSF-derived findings
- display contracts
- artifact delivery through agent-gateway/data-service

No generic pipeline code should mention OSV ScaLibr, Trivy, Falco, or any future scanner as a special case unless it is rendering or validating that scanner's source-owned contract. Scanner-specific naming, plugin configuration, version metadata, and output translation belong inside the add-on package and its submitted contracts.

### OSV ScaLibr is the first endpoint inventory scanner add-on
OSV ScaLibr is selected as the first implementation of the endpoint inventory scanner add-on because it provides host filesystem extraction, SBOM output, Linux container image analysis, and custom extraction/detection plugins. The add-on wraps ScaLibr as a Go library by creating a `scalibr.ScanConfig`, selecting extraction/detection plugins, calling `scalibr.New().Scan()`, and translating `ScanResults` into the generic ServiceRadar inventory/SBOM/scan/finding contracts.

ScaLibr SHALL NOT become a core/web-ng dependency and SHALL NOT send results directly to NATS or web-ng. For host scanning it runs under the normal assigned add-on path on eligible agents. For Linux container image scanning it runs as an add-on in a deployment context that can access the image reference or tarball, then submits scan/SBOM/finding events through the same gateway-backed add-on event path.

Trivy remains the Kubernetes/container report ingestion path because it already produces cluster-scoped vulnerability and compliance reports. ScaLibr may later cover image/tarball scan gaps where a scanner add-on can run close to the image artifact. Vulnerability enrichment from external feeds is produced by intelligence add-ons/plugins as normalized advisory batches; agents submit inventory/SBOM evidence and scanner findings, not feed-matching jobs.

The current hand-rolled package manager collectors are compatibility/fallback code only. New endpoint inventory collection work should improve the scanner add-on contract and the ScaLibr add-on translation layer rather than extending bespoke dpkg/rpm/apk parsing, except for bounded bug fixes needed while migrating.

### Existing architecture boundaries hold
Agents and add-ons SHALL continue to receive config and artifacts through agent-gateway. The control plane stores contracts, assignments, diagnostics, and ingested results; it does not reach out to add-ons at runtime to ask how to process them.

## Risks
- Profile reconciliation touches SRQL, Ash resources, assignment materialization, and LiveView; tests need to cover both core and web-ng.
- Adding diagnostics to the scan payload must preserve bounded payload size and compatibility with older agents.
- A default `in:devices` profile can target more hosts than expected; preview and caps must be explicit before enablement.
- Vulnerability feeds can be large; producer add-ons need object-store quota controls, bounded advisory batches, retry/backoff, and visible ingestion errors.
- CPE matching can over-report on distro-patched packages; the matcher must preserve confidence and evidence instead of presenting every CPE hit as certain.
- Adding both Trivy and ScaLibr scanner paths can create duplicate findings unless the scan source, scope, and dedupe keys are explicit.
