## 1. Profile Reconcile Correctness
- [x] 1.1 Fix `AddonProfile` action implementations to access Ash action context as a struct and avoid `context[:actor]`.
- [x] 1.2 Add tests for `preview` and `reconcile_now` actions that would fail if the action context is treated as an Access map.
- [x] 1.3 Ensure LiveView reconcile and preview handlers catch structured `{:error, reason}` returns and show bounded errors without terminating the LiveView.
- [x] 1.4 Normalize a blank endpoint inventory profile target query to `in:devices`.

## 2. Profile Targeting And Eligibility
- [x] 2.1 Extend profile preview results to report matched SRQL rows, resolved devices, resolved agents, eligible agents, and skipped targets.
- [x] 2.2 Add skip reasons for no enrolled agent, unsupported platform, incompatible base agent version, missing required capability, revoked/unapproved package, disabled package config, manual override, and disconnected control stream.
- [x] 2.3 Persist the most recent reconcile report so agent add-on views and endpoint inventory setup can show provenance and last failure state.
- [x] 2.4 Add tests for profile reconciliation from `in:devices`, including devices with no agent, incompatible agents, and manual override assignments.

## 3. Endpoint Inventory Collection Diagnostics
- [x] 3.1 Extend the generic scanner inventory/status payload with enabled sources/plugins, detected sources/plugins, per-source/plugin package counts, per-source/plugin skipped/error reasons, collector version, config hash, truncation state, and duration.
- [x] 3.2 Preserve diagnostics through spool validation, result routing, ingest, and current scan state.
- [x] 3.3 Mark scans with zero or unexpectedly low package counts as healthy only when source diagnostics show complete enabled-source coverage.
- [x] 3.4 Add tests for generic scanner plugin/source diagnostics plus fallback dpkg/rpm/apk missing-source, permission-denied, timeout, and output-truncation diagnostics.
- [x] 3.5 Add a reusable scanner add-on adapter interface/contract that translates scanner-native output into ServiceRadar inventory/SBOM scan activity, findings, diagnostics, and display contracts without hardcoding scanner names in agent/core/gateway pipelines.
- [x] 3.6 Implement the first endpoint inventory scanner add-on with OSV ScaLibr, translating `ScanResults` into the generic ServiceRadar inventory/SBOM scan contract.
- [x] 3.7 Keep existing hand-rolled package manager collectors only as compatibility/fallback code during migration; do not add new bespoke package extraction features outside scanner add-on implementations.

## 4. Endpoint Inventory UX
- [x] 4.1 Simplify endpoint inventory setup around one primary profile workflow: target query, preview, enable, reconcile.
- [x] 4.2 Move raw JSON, package-manager paths, spool paths, max output bytes, force-full intervals, and other low-level fields into an Advanced section.
- [x] 4.3 Show the latest selected endpoint inventory add-on package/release by default and explain when no approved package is available.
- [x] 4.4 Show assignment provenance and profile reconcile state next to every endpoint inventory assignment.
- [x] 4.5 Keep manual agent assignment available as an advanced override and label it as overriding profile ownership.

## 5. Device Details Software Tab
- [x] 5.1 Add a Software tab to the device details screen for endpoint package inventory.
- [x] 5.2 Move endpoint package lists and scan status out of generic device detail panels into the Software tab.
- [x] 5.3 Display freshness, total package count, package manager breakdown, source diagnostics, partial/failed state, and last successful scan metadata.
- [x] 5.4 Add package search/filtering by name, version, package manager, PURL, and CPE where available.
- [x] 5.5 Show clear empty states for not enabled, no enrolled agent, no scan yet, stale scan, partial scan, and failed scan.
- [x] 5.6 Show device-scoped vulnerability matches, KEV/exploit enrichment, affected package evidence, fixed version, source feed, and finding status when available.

## 6. Vulnerability Feeds And Matching
- [x] 6.1 Inventory current endpoint SBOM/package generation, upload, object storage, and ingest path; document where SBOM artifacts live and which code owns each hop.
- [x] 6.2 Add generic vulnerability intelligence source definitions and settings UI for add-on/plugin-registered sources.
- [x] 6.3 Add an add-on SDK advisory-feed contract so feed producers can submit normalized advisory batches without core provider branches.
- [x] 6.4 Store accepted advisory snapshot provenance through datasvc object-storage metadata supplied by producers, with retention/quota metadata.
- [x] 6.5 Ingest producer-normalized advisory records into CNPG with CVE/advisory id, affected coordinates, severity/CVSS, KEV/exploit metadata, references, and source object identity.
- [x] 6.6 Implement bounded central matcher jobs from advisory coordinates to endpoint package/SBOM coordinates; do not run feed matching on agents.
- [x] 6.7 Emit/update device-scoped OCSF Vulnerability Findings and endpoint inventory risk summaries with package evidence and match confidence.
- [x] 6.8 Add fixture tests for advisory batch ingestion, malformed coordinate rejection, add-on SDK advisory contract shape, and matcher outcomes.
- [x] 6.9 Keep threat intelligence feed producers separate from endpoint inventory, with native add-ons and Wasm plugins both using runtime-neutral, agent-gateway-mediated artifact/config/credential APIs rather than direct object-store access.
- [x] 6.10 Add advisory-feed helper types/builders to the Go and Rust Wasm plugin SDKs, so third-party producers do not hand-roll contract JSON when emitting normalized advisory batches through plugin results.
- [x] 6.11 Add or specify gateway-backed Wasm/plugin SDK artifact helpers for feed producers that need durable snapshot staging, object metadata, digest validation, and chunked/streamed object transfer.
- [x] 6.12 Implement the agent Wasm host runtime and agent-gateway upload path behind `artifact-staging:v1`, so `artifact_open`/`artifact_write`/`artifact_commit`/`artifact_abort` stream to datasvc through agent-gateway instead of failing at runtime or bypassing the object boundary.

## 7. Scanner Signal Extraction And Security UX
- [x] 7.1 Update Trivy ingestion so aggregate `VulnerabilityReport` events expose child vulnerability findings with CVE, title, severity, installed version, fixed version, artifact, resource, namespace, references, and source report linkage.
- [x] 7.2 Update Falco ingestion so runtime detections expose rule, priority, source, output fields, host/workload/container/process/user/file/network evidence, references, and source event linkage.
- [x] 7.3 Add or migrate Trivy and Falco processor/display contracts so Event Viewer and `/security` render useful summaries and child findings without hardcoding raw payload shapes in web-ng.
- [x] 7.4 Update `/security` so Trivy report rows drill into individual vulnerabilities and Falco rows drill into runtime detection evidence; raw Event Details links remain secondary audit context.
- [x] 7.5 Ensure scanner findings correlate to devices, workloads, images, packages, and raw events where metadata is available.
- [x] 7.6 Add dedupe and active finding identity tests for replayed Trivy report revisions and repeated Falco alerts.
- [x] 7.7 Differentiate `/security` as a tactical investigation/work queue from `/dashboards/security-findings` as a customizable posture dashboard, with links between them.
- [x] 7.8 Make security summary cards and dashboard posture cards clickable drill-down controls with scoped filters or detail destinations.
- [x] 7.9 Add disabled/empty card states that explain missing data or unavailable source conditions instead of linking to generic empty pages.
- [x] 7.10 Update the Security Findings authored dashboard to focus on editable posture/trend panels rather than duplicating the tactical `/security` finding table.
- [x] 7.11 Select a scanner-agnostic add-on contract, with OSV ScaLibr as the first endpoint inventory scanner implementation and Trivy remaining the Kubernetes/container report ingestion path.
- [x] 7.12 Implement ScaLibr only as a signed scanner add-on through the add-on SDK and normal agent-gateway/data-service paths; do not add ScaLibr-specific branches or dependencies to agent/core/gateway pipelines.

## 8. Validation
- [x] 8.1 Add core tests for add-on profile preview/reconcile reports.
- [x] 8.2 Add web-ng LiveView tests for endpoint inventory setup, reconcile failure handling, and the Software tab empty/partial states.
- [x] 8.3 Add or update endpoint inventory collector tests for generic scanner plugin/source diagnostics and fallback source diagnostics.
- [x] 8.4 Add web-ng tests for `/security` Trivy child finding drill-down, Falco detection detail, Event Viewer display contracts, raw fallback behavior, clickable card drill-down filters, and differentiation from `/dashboards/security-findings`.
- [x] 8.5 Validate web-ng locally against demo CNPG with `$demo-cnpg-local-web-ng`.
- [x] 8.6 Capture Playwright screenshots for endpoint inventory setup, device Software tab, tactical `/security`, customizable `/dashboards/security-findings`, clickable card drill-down states, Trivy finding drill-down, and Falco detection detail.
- [x] 8.7 Document the endpoint inventory profile workflow, vulnerability feed setup, scanner signal contracts, and diagnostics in `docs/docs`, updating `sidebars.ts` for any new docs page.

## 9. Producer Schedule Contracts
- [x] 9.1 Extend plugin/add-on package manifests and SDK helper types with a generic producer schedule contract: schedule id, action/command id, default cadence, cadence bounds, optional cron support, jitter, required settings, credential refs, payload template, redaction hints, and dispatch scope.
- [x] 9.2 Persist package-declared schedule contracts when packages are imported, staged, approved, or upgraded without provider-specific core branches.
- [x] 9.3 Add generic platform schedule state for operator choices: enabled, cadence or cron, target assignment/SRQL policy, params, credential refs, last run, next due, last command id, last status, and last error.
- [x] 9.4 Add an AshOban-backed producer schedule worker owned by core-elx that scans due schedules, dispatches package-declared commands through agent commandbus, and records status/error/next-due state.
- [x] 9.5 Use existing `plugin.run_action` for Wasm producer schedules that reference plugin actions, including run-now dispatch from settings UI.
- [x] 9.6 Render vulnerability feed schedule controls in web-ng from package schedule contracts and schedule state, with no CISA/NVD/VulnCheck/OSV hardcoded forms.
- [x] 9.7 Add SDK examples/tests proving a Wasm advisory feed producer can declare a schedule and emit advisory batches/artifact snapshot provenance through the generic contract.
- [x] 9.8 Add DB-backed tests for schedule contract persistence, cadence validation, due-run dispatch, run-now dispatch, and stale/error status reporting.
- [x] 9.9 Add native add-on scheduled execution through generic `addon.run_command`, delivered over agent commandbus through agent-gateway to the selected agent and local add-on gRPC `RunCommand` RPC.
