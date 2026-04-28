## 1. Proposal
- [ ] 1.1 Review existing settings, Oban, NetFlow, and DNS query patterns.
- [ ] 1.2 Draft OpenSpec proposal, design, tasks, and spec deltas.
- [ ] 1.3 Validate the change with `openspec validate add-alienvault-otx-integration --strict`.
- [ ] 1.4 Get proposal approval before implementation.

## 2. Data Model
- [ ] 2.1 Add platform-schema migrations for OTX settings, sync runs, pulses, indicators, retrohunt runs, and findings.
- [ ] 2.2 Add Ash resources/actions/policies for the new tables.
- [ ] 2.3 Add encrypted API key handling with "present" calculations and clear/update actions.
- [ ] 2.4 Add indexes for indicator type/value, pulse modified time, active/expiration state, and finding lookup.

## 3. OTX Client And Sync
- [ ] 3.1 Implement a project-owned OTX client using `Req`.
- [ ] 3.2 Support `X-OTX-API-KEY`, configurable base URL, timeouts, retry/backoff for 429/5xx, pagination, and `modified_since`.
- [ ] 3.3 Normalize pulse and indicator payloads into Ash resources.
- [ ] 3.4 Record sync lifecycle status, counts, and redacted errors.
- [ ] 3.5 Archive raw payload snapshots to NATS Object Store when enabled.

## 4. Retroactive Hunting
- [ ] 4.1 Implement an Oban worker that batches newly imported indicators.
- [ ] 4.2 Query the configured historical window for IP indicators against NetFlow source/destination data.
- [ ] 4.3 Query domain/hostname indicators against the canonical DNS aggregate data.
- [ ] 4.4 Store deduplicated retrohunt findings with enough evidence to explain the match.
- [ ] 4.5 Make unsupported indicator types visible as imported but not retrohunt matched.

## 5. Settings And Visibility UI
- [ ] 5.1 Add an authenticated Settings route and navigation entry for OTX/Threat Intel.
- [ ] 5.2 Add an encrypted API key form that never echoes the saved key.
- [ ] 5.3 Add toggles and numeric controls for sync interval, retrohunt window, raw archival, and enabled state.
- [ ] 5.4 Add status panels for last sync, indicator counts, latest errors, and manual "Sync now" / "Retrohunt now" actions.
- [ ] 5.5 Add an operator findings view or panel for historical matches.

## 6. Scheduling And Operations
- [ ] 6.1 Register the OTX sync job with Oban cron and uniqueness settings.
- [ ] 6.2 Use safe enqueue behavior when Oban is unavailable.
- [ ] 6.3 Emit logs/telemetry for sync and retrohunt lifecycle without leaking secrets.
- [ ] 6.4 Document deployment secret/env var options and API key rotation expectations.

## 7. Validation
- [ ] 7.1 Add unit tests for OTX client pagination, auth header use, and error handling.
- [ ] 7.2 Add Ash resource tests for encrypted key updates and redacted reads.
- [ ] 7.3 Add worker tests for import idempotency and retrohunt deduplication.
- [ ] 7.4 Add LiveView tests for RBAC, save/clear key behavior, and manual job enqueue.
- [ ] 7.5 Run `MIX_ENV=test mix compile --warnings-as-errors`, focused tests, and `mix precommit` where applicable.
