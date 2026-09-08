---
id: endpoint-software-security
title: Endpoint Software Security
sidebar_label: Endpoint Software Security
---

# Endpoint Software Security

ServiceRadar separates endpoint software collection from vulnerability matching.
Agents and add-ons collect package and SBOM evidence. Vulnerability intelligence
add-ons or Wasm plugins own feed downloads, provider-specific validation, and
advisory normalization. The control plane owns the generic advisory contract,
source/snapshot metadata, matching, risk scoring, and finding display.

The runtime boundary is intentionally neutral. Native add-ons are not required
just because a producer needs durable artifacts, credentials, or large feed
snapshots. Wasm plugins and native add-ons both use logical ServiceRadar APIs
brokered by agent-gateway. Neither runtime receives direct NATS JetStream Object
Store credentials.

## Data Path

Endpoint software inventory follows this path:

1. The endpoint inventory scanner add-on or compatibility collector runs on an
   eligible agent.
2. The agent submits a bounded inventory payload through agent-gateway. Agents do
   not talk to web-ng or NATS JetStream directly.
3. `ServiceRadar.Inventory.EndpointInventoryIngestor` validates the payload,
   normalizes packages, preserves scanner diagnostics, and records an OCSF Scan
   Activity event.
4. If the payload includes a CycloneDX SBOM, `EndpointInventoryArtifactStore`
   uploads the raw SBOM through datasvc object storage.
5. `EndpointInventoryArtifactPersistence` stores artifact metadata in
   `platform.endpoint_inventory_artifacts` and de-duplicates raw content in
   `platform.endpoint_inventory_artifact_contents`.
6. Current package rows are stored in `platform.endpoint_inventory_packages` and
   normalized package coordinates are stored in `platform.endpoint_packages`.
7. The central matcher retains coordinate-level evidence in
   `platform.endpoint_vulnerability_matches` and writes one stable applicability
   decision per device/package/CVE to
   `platform.endpoint_vulnerability_assessments`.

The raw SBOM object key is a content-addressed path:

```text
endpoint-inventory/by-hash/<sha256>.cdx.json
```

The object store is durable evidence storage. The CNPG rows are the query and UI
surface.

## Scanner Contracts

Scanner add-ons should emit generic ServiceRadar contracts:

- scan activity metadata
- package rows and SBOM artifacts
- scanner plugin/source diagnostics
- OCSF-derived findings
- display contracts for event and security views

The shared agent, gateway, ingest, database, and UI paths should not special-case
scanner implementations. Scanner-specific details such as OSV ScaLibr plugin
names, output translation, native config, and version metadata belong inside the
scanner add-on package and the contracts it submits.

The existing package-manager collectors are compatibility fallback code during
the migration to scanner add-ons. New extraction work should target scanner
add-ons rather than adding more bespoke parser code to the agent.

## Endpoint Inventory Profiles

Use **Settings > Agents > Endpoint Inventory** to control where endpoint
software inventory runs. Profiles target agents with SRQL, so the normal path is
to define the desired device cohort once and let reconciliation create the
add-on assignments.

Recommended workflow:

1. Create or edit an endpoint inventory profile.
2. Set the target SRQL query, for example `in:devices` for every eligible agent
   or a narrower query such as `in:devices hostname:%pve%`.
3. Enable the profile.
4. Reconcile the profile. Reconciliation evaluates the SRQL query, filters for
   eligible connected agents, and creates or updates the endpoint inventory
   add-on assignments.
5. Open a device and use the **Software** tab to confirm the latest scan,
   package rows, source diagnostics, SBOM artifact hashes, and vulnerability
   matches.

Operators should not have to manually assign the endpoint inventory add-on to
each agent after defining a profile. Manual assignment is useful for break-glass
or one-off testing, but SRQL-backed profiles are the fleet workflow.

If the Software tab says a scan reported many packages but only a few current
rows loaded, treat that as an ingest or retention problem. The scan summary,
source diagnostics, package-set hash, artifact hash, and upload reason are shown
so the operator can distinguish "scanner found nothing" from "scanner found
packages but persistence did not keep them."

## Fleet queries (SRQL)

The Software tab is per-device. For fleet questions use SRQL. Walkthrough:
[Threat Investigation](./threat-investigation.md).

```srql
in:devices kev:true
in:devices cve:CVE-2024-1234
in:endpoint_packages cve:CVE-2024-1234 current:true
in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:% current:true
in:cve_matches status:active assessment:confirmed disposition:affected kev:true sort:cvss_score:desc
in:cve_matches stats:count() as audit_rows
in:cve_matches status:active assessment:confirmed disposition:affected stats:count() as exposed
in:cves cve:CVE-2024-1234
in:advisory_cpes cve:CVE-2024-1234 coordinate_type:cpe
```

`in:cves` is the global catalog. `in:cve_matches` is a compatibility alias for
the assessment-grain deployment view, including candidates and resolved
history. Its unqualified `stats:count()` counts persisted audit/state rows, not
exposure; exposure counts require the exact active + confirmed + affected
filters shown above. `in:endpoint_packages cpe:` is installed CPE overlap, not
NVD version matching. There is no `in:devices cpe:` and no `in:cpes` entity.

## Vulnerability Intelligence Sources

Vulnerability feeds are normally source-owned. A native add-on or Wasm plugin
fetches, validates, and normalizes provider data, then submits a
`serviceradar.advisory_feed.contract.v1` batch. Canonical's paired Ubuntu
OSV/OpenVEX publication is the deliberate built-in exception: core acquires
both archives atomically and consumes a bounded normalized projection so distro
version and not-affected evidence retain their authority.

### Built-in feed enablement

At boot, core seeds Ubuntu OSV + OpenVEX (`ubuntu-osv-vex`) enabled by
default. CISA KEV, VulnCheck KEV, and NVD start disabled until an operator
enables them. On upgrade, core also enables an existing disabled Ubuntu row
only if it has no attempt, success, or failure timestamps and its creation and
update timestamps are equal. Previously edited or attempted rows retain their
settings, including an operator's disablement.

If Ubuntu was previously edited or attempted while disabled, enable it in
**Settings -> Security -> Vulnerability Feeds** when Ubuntu matching is wanted.
Enablement alone does not confirm vulnerable packages: the feed must complete
a validated OSV/OpenVEX generation and the matcher must run against that evidence.

Each source definition tracks:

- provider and feed key
- enablement
- contract type
- retention period
- last submit status and error
- add-on/plugin provenance in metadata

Operators can disable matching for a registered source from the control plane.
Changing provider URLs, credentials, schema rules, and download cadence is owned
by the producer package rather than core.

Common first-party sources include CISA KEV, NVD/NIST feeds, VulnCheck KEV, and
VulnCheck NVD mirrors. Third-party producers can add more sources without core
code changes when they emit the same advisory batch contract.

Credential and artifact handling is always gateway-mediated:

- Producers ask the host SDK for named credentials instead of reading platform
  secrets directly.
- Producers stage raw or normalized snapshots through artifact APIs such as
  open, write, commit, abort, metadata, and digest validation.
- The agent forwards those calls to agent-gateway, and agent-gateway writes to
  the internal object path.
- Producers submit advisory batches with the committed object identity and
  validation metadata.

Do not build a producer that writes directly to NATS JetStream Object Store or
calls web-ng from an agent. That bypasses ServiceRadar's edge trust boundary.

## Scheduled Feed Producers

Feed producers that need recurring downloads declare `producer_schedules` in
their package manifest. The schedule contract is owned by the plugin or add-on
package and includes the action id, cadence bounds, optional cron support,
jitter, required settings, credential requirements, payload template, and target
scope. Core persists that contract when the package is imported or approved.

Operators configure cadence, enablement, credentials, and target scope from
**Settings -> Security -> Vulnerability Feeds**. The UI is generated from the
package contract and stores operator choices separately from the package
manifest, so upgrading a producer does not silently overwrite local schedule
state.

Due runs are dispatched by the core AshOban scheduler through the existing agent
commandbus. Wasm producers use `plugin.run_action`; native add-on producers use
`addon.run_command`. Both receive a `serviceradar.producer_schedule_run.v1`
payload through agent-gateway and the selected agent. Credential selections are
converted into scoped broker grants before the command reaches the agent; raw
credential refs remain platform state. Producers never receive direct access to
web-ng, core-elx, or NATS JetStream object storage.

## Snapshot Validation

Accepted raw or normalized feed snapshots are stored by the producer through
gateway-mediated artifact storage under a producer-owned object key such as:

```text
vulnerability-feeds/<provider>/<feed-key>/<sha256>.<format>
```

The control plane records producer-supplied snapshot metadata in
`platform.vulnerability_feed_snapshots`, including source URL when provided,
object key, content hash, validation result, size, and accepted timestamp.

Provider-specific validation happens in the producer. For example, a CISA KEV
producer should validate the published JSON Schema, and a VulnCheck producer
should verify backup pointer SHA-256 values before submitting a batch. Core
records that validation result but does not implement those provider parsers.

Large pointer JSON feeds and zip archives can be processed by a Wasm plugin when
the Wasm host exposes the needed gateway-backed APIs for credentials, bounded
download, chunked artifact writes, digest validation, and scheduling. Use a
native add-on only when the producer needs runtime capabilities outside the Wasm
sandbox, not because it needs the object store.

## Advisory Normalization

Accepted producer records are stored in `platform.vulnerability_advisories`.
An advisory preserves:

- provider and feed key
- source object identity
- CVE or advisory id
- severity and CVSS fields when available
- publication and modified timestamps
- KEV or exploit metadata
- references
- affected coordinates and match semantics

Affected coordinates keep their type. CPE, PURL, package, ecosystem, vendor, and
version range data should not be collapsed into an opaque string because the
matcher must be able to explain why a package matched.

## Matching

Matching runs in the control plane. Agents do not download vulnerability feeds and
do not run feed matching jobs.

The matcher reads current endpoint package rows, advisory coordinates, and
distro assertions. It retains raw coordinate matches as supporting evidence and
writes one stable device/package/CVE assessment with:

- device UID and agent id
- endpoint package and scan references
- CVE/advisory identity and authoritative provider
- installed, introduced, and fixed-version evidence
- confirmed or candidate assessment and affected/fixed/not-affected disposition
- authority, applicability reason, and freshness
- supporting raw-match and normalized-assertion IDs
- KEV and exploit flags
- first seen, last seen, and resolved timestamps

Only an active, confirmed, affected assessment is actionable. The Software tab
shows those decisions beside the inventory that produced them while retaining
candidates and resolved history for investigation. Raw match and event rows
remain evidence and audit context, not the primary remediation workflow.

## Security Views

Endpoint inventory, Trivy, Falco, Bumblebee, and PowerDNS all feed the Security
experience through OCSF-derived contracts.

- `/security` is the triage entry point. It links to the canonical security
  dashboard, common SRQL drill-downs, feed settings, and selected finding or
  detection detail panels.
- `/dashboards/security-findings` is the canonical data surface for current
  security posture. It owns source coverage, security finding severity, scan
  activity, DNS security activity, normalized vulnerability rows, and editable
  SRQL-backed widgets.
- Device **Software** tabs are the remediation view for host packages and
  endpoint vulnerability assessments.
- Raw event pages are audit and troubleshooting context. Integrations should
  ship display contracts so event details expose useful fields before the raw
  JSON.

Trivy report events are aggregate lifecycle records. The actionable rows are the
child vulnerability findings: CVE, title, severity, affected package or image,
installed version, fixed version, resource, namespace, references, and observed
time. Falco detection details should expose rule, priority, process/container,
Kubernetes node/pod, device correlation, and source evidence.

## Diagnostics

Use these checks when endpoint inventory or scanner data looks incomplete:

- Confirm the agent is connected and advertises the endpoint inventory
  capability.
- Reconcile the endpoint inventory profile and verify the add-on assignment
  state.
- Open the device **Software** tab and compare reported package count with
  loaded current rows.
- Review source diagnostics for failed package managers, truncated output, or
  disabled sources.
- Check package-set hash and artifact hash changes to verify whether a new scan
  produced new evidence.
- Check `/dashboards/security-findings` for scan activity and source coverage.
- Use `/security` when starting triage or opening a bookmarked finding or
  detection detail panel.
- Use Observability drill-downs for raw OCSF events when a display contract or
  normalized child row is missing.
- If normalized Trivy child rows are empty while aggregate Trivy events exist,
  verify the Trivy child-finding migration is applied and backfill or replay the
  report events.
