## 1. Proposal
- [x] 1.1 Review existing settings, Oban, NetFlow, and DNS query patterns.
- [x] 1.2 Draft OpenSpec proposal, design, tasks, and spec deltas.
- [x] 1.3 Validate the change with `openspec validate add-alienvault-otx-integration --strict`.
- [x] 1.4 Get proposal approval before implementation.

## 2. Data Model
- [x] 2.1 Extend existing NetFlow threat-intel settings with OTX enabled/base URL/API key/sync status fields, or add a narrowly scoped companion singleton if that is cleaner.
- [x] 2.2 Reuse `platform.threat_intel_indicators` for OTX IPv4/IPv6/CIDR indicators with source `alienvault_otx`.
- [x] 2.3 Add provider/source object metadata storage for TAXII/STIX object ids, versions, collection ids, raw object keys, and OTX pulse metadata if needed for richer hit explanation.
- [x] 2.4 Add encrypted OTX API key handling with "present" calculations and clear/update actions.
- [x] 2.5 Add indexes or constraints for any new provider metadata/sync tables.
- [x] 2.6 Track provider execution mode (`edge_plugin` or `core_worker`), plugin assignment identity, cursor/high-water state, and sync status.

## 3. TAXII/STIX Provider Boundary And OTX Sync
- [x] 3.1 Define a project-owned threat-intel provider behaviour modeled after TAXII 2.1 collections, object pages, `added_after`, `limit`, `next`, and object metadata.
- [x] 3.2 Implement STIX 2.1 Indicator normalization for supported IP/CIDR patterns.
- [x] 3.3 Implement a project-owned OTX client using `Req`.
- [x] 3.4 Support `X-OTX-API-KEY`, configurable base URL, timeouts, retry/backoff for 429/5xx, pagination, and `modified_since`.
- [x] 3.5 Extend `ThreatIntelFeedRefreshWorker` or add a sibling worker to fetch `/api/v1/pulses/subscribed` through the provider boundary.
- [x] 3.6 Normalize OTX IPv4/IPv6/CIDR indicators into `ThreatIntelIndicator` rows.
- [x] 3.7 Record skipped counts for unsupported OTX types such as URL, domain, hostname, and file hash until matching sources are implemented.
- [x] 3.8 Record sync lifecycle status, counts, and redacted errors.
- [x] 3.9 Archive raw payload snapshots to NATS Object Store when enabled.
- [ ] 3.10 Optionally implement a generic TAXII 2.1 collection provider if approved for this slice.

## 4. Edge Wasm Collector
- [x] 4.1 Define the CTI plugin output contract as a typed `threat_intel` block inside JSON-encoded `serviceradar.plugin_result.v1` details.
- [x] 4.2 Keep manifest validation unchanged because this slice does not add a dedicated plugin output type.
- [x] 4.3 Select `serviceradar-sdk-go` for the first built-in collector because it is already exercised by existing first-party plugins.
- [x] 4.4 Build a first-party AlienVault OTX collector plugin using the selected SDK.
- [x] 4.5 Add plugin config schema fields for provider URL, auth secret reference, page size, high-water cursor, timeout, and bounded indicator count.
- [x] 4.6 Ensure the plugin uses only approved host capabilities and allowlists for HTTP access to OTX.
- [x] 4.7 Route edge plugin CTI pages through core validation, normalization, and indicator upsert.
- [x] 4.8 Add UI affordances to assign the collector plugin to reachable agents with secret-reference OTX credentials.
- [x] 4.9 Display per-agent sync health for threat-intel collector assignments.

## 5. NetFlow Threat Matching
- [x] 5.1 Reuse `NetflowSecurityRefreshWorker` for recent NetFlow matching.
- [x] 5.2 Make the current/recent NetFlow match lookback configurable instead of hard-coded where needed.
- [x] 5.3 Ensure OTX/source names and max severity appear in `IpThreatIntelCache` results.
- [x] 5.4 Surface OTX/TAXII/SIEM hit counts and source context in NetFlow analysis views.
- [x] 5.5 Make unsupported indicator types visible in sync status as imported/skipped but not NetFlow-match supported.

## 6. Optional Retroactive Hunting
- [x] 6.1 Implement an operator-triggered retrohunt worker for historical backfill.
- [x] 6.2 Query the configured historical window for IP indicators against NetFlow source/destination data.
- [ ] 6.3 Query domain/hostname indicators against the canonical DNS aggregate data where available.
- [x] 6.4 Store deduplicated retrohunt findings with enough evidence to explain the match.
- [x] 6.5 Keep retrohunt disabled or manual by default unless settings explicitly enable scheduled backfill.

## 7. Settings And Visibility UI
- [x] 7.1 Add an authenticated Settings route and navigation entry for OTX/Threat Intel.
- [x] 7.2 Add encrypted API key/secret-reference forms that never echo saved secrets.
- [x] 7.3 Add toggles and numeric controls for execution mode, sync interval, recent NetFlow lookback, retrohunt window, raw archival, and enabled state.
- [x] 7.4 Add status panels for last sync, indicator counts, latest errors, and edge agent/plugin health.
- [x] 7.6 Add manual "Retrohunt now" actions.
- [x] 7.8 Add manual OTX "Sync now" action.
- [x] 7.5 Add operator visibility for OTX findings in NetFlow analysis and/or a dedicated threat-intel findings view.
- [x] 7.7 Add operator visibility for imported OTX indicators and source-object metadata.
- [x] 7.9 Add current NetFlow finding counts to the Threat Intel settings page.

## 8. Scheduling And Operations
- [x] 8.1 Register core-hosted OTX sync jobs with Oban uniqueness settings.
- [x] 8.2 Register edge plugin schedules through plugin assignments/target policies.
- [x] 8.3 Register current/recent NetFlow matching work with uniqueness and bounded batch sizes.
- [x] 8.4 Use safe enqueue behavior when Oban or plugin scheduling is unavailable.
- [x] 8.5 Emit logs/telemetry for sync, NetFlow matching, edge plugin runs, and retrohunt lifecycle without leaking secrets.
- [x] 8.6 Document deployment secret/env var options, plugin secret references, egress allowlist review, and API key rotation expectations.

## 9. Validation
- [x] 9.1 Add unit tests for TAXII/STIX page normalization and STIX Indicator pattern extraction.
- [x] 9.2 Add unit tests for OTX client pagination, auth header use, and error handling.
- [x] 9.3 Add plugin contract tests for bounded CTI page payloads, config decoding, secret redaction, and allowlist failures.
- [x] 9.4 Add Ash resource tests for encrypted key updates and redacted reads.
- [x] 9.5 Add worker/ingestor tests for OTX import idempotency, unsupported type counts, NetFlow cache matching, and retrohunt deduplication.
- [ ] 9.6 Add LiveView tests for RBAC, save/clear key behavior, findings visibility, plugin assignment controls, and manual job enqueue.
- [ ] 9.7 Run `MIX_ENV=test mix compile --warnings-as-errors`, focused tests, plugin build/tests, and `mix precommit` where applicable.
