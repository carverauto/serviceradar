Sections 1-3 record the shipped fail-closed recovery baseline. Section 4
supersedes its row-by-row operator workflow; checked tasks below are historical
implementation status, not the target user experience.

## 1. Domain and authorization

- [x] 1.1 Define a tenant-scoped legacy-assignment recovery read model that classifies unbound manual and policy rows without treating current agent metadata as historical proof.
- [x] 1.2 Add a read-only authenticated-control-session preview that reports the selected agent's current partition or a fail-closed unavailable/mismatch state.
- [x] 1.3 Implement an explicit manual reapproval action that re-resolves mTLS evidence at commit time, creates a fresh assignment through the normal create path, and preserves the old row disabled.
- [x] 1.4 Add an idempotent audit relation/event for recovery decisions, replacement IDs, actor, and authenticated principal tuple, with redaction of secret material and an exact internal-only raw-audit lookup.
- [x] 1.5 Implement scoped policy/credential-rule reconciliation for policy-owned legacy rows; reject manual cloning and deny actors without authority over the owner.
- [x] 1.6 Enforce tenant scope and explicit initiating actor for all user-facing recovery and preview actions.
- [x] 1.7 Add legacy-row-authorized, redacted policy-recovery and manual-completion projections that cannot enumerate durable recovery requests or raw audits, or disclose their payloads.

## 2. Plugin assignment UI and API

- [x] 2.1 Display the authenticated partition state after an agent is selected and explain that it is derived from the live mTLS session, not configurable by the user.
- [x] 2.2 Render distinct legacy recovery state for unbound manual versus policy-owned assignments, including source, reason, and non-secret configuration compatibility errors.
- [x] 2.3 Add a confirmation-driven manual reapproval action and an authorized policy-reconcile action with clear success, conflict, identity-change, offline, and denied states.
- [x] 2.4 Ensure regular assignment creation, update, and upgrade flows do not accidentally route legacy rows through an immutable update path.
- [x] 2.5 Keep `partition_id` absent from editable form/API parameters and redact secret values in every response and LiveView assignment.
- [x] 2.6 Show tenant-scoped, redacted policy-reconciliation state and completed manual-reapproval state in package detail, refresh queued/running work, and give safe terminal remediation without rendering durable-request internals.
- [x] 2.7 Require credential-management authority in addition to plugin-assignment authority for credential-rule reconciliation in the UI, including direct LiveView-event rejection, while retaining server-side authorization.
- [x] 2.8 Add a tenant-scoped, bounded keyset-paged legacy recovery candidate review table with an explicit package-review path, completed-row removal, and no bulk enable/default-partition workflow.

## 3. Verification and operations

- [x] 3.1 Add domain tests for default-partition creation, offline/missing/mismatched evidence, actor and tenant denial, package/schema failure, active conflict, and idempotent retry.
- [x] 3.2 Add tests proving manual recovery copies secret references only and never raw secrets, logs, or audit payloads.
- [x] 3.3 Add materializer tests for policy recovery, stale/deleted owner rejection, source-authority authorization, and fenced lease ownership.
- [x] 3.4 Add LiveView/API tests for authenticated-partition display, no partition selector, manual confirmation and completion, policy-only reconciliation, credential-rule permission messaging, redacted internal-only status/audit access, keyset candidate paging, and actionable error states.
- [x] 3.5 Run the focused core and LiveView suites plus strict OpenSpec validation against the completed recovery implementation.
- [x] 3.6 Write an operator runbook for reviewing recovery candidates and reconciling the demo inventory.

## 4. Automatic recovery and exception-only UX correction

- [ ] 4.1 Add a tenant-scoped logical recovery planner and item store that groups duplicate legacy rows by owner, agent, and logical plugin; fingerprints current inputs; and converges under concurrent scans and retries.
- [ ] 4.2 Trigger bounded automatic policy and credential-rule reconciliation after deployment, agent connection, owner/package changes, and periodic sweep using current controller authority and current owner materialization only.
- [ ] 4.3 Add an immutable, expiring manual adoption plan with one tenant-scoped confirmation, per-item initiating-principal reauthorization, current mTLS rechecks, automatic reconnect retry, and idempotent conflict handling.
- [ ] 4.4 Define and test the strict allowlist for automatic manual principal continuity; if no existing evidence qualifies, route every manual item through the single adoption plan without weakening identity checks.
- [ ] 4.5 Replace row/request-oriented UI projections with tenant-authorized aggregate progress, normalized exception groups, bounded on-demand agent detail, and internally fenced plan/item/request/audit records.
- [ ] 4.6 Remove legacy cards, repeated warning panels, raw package UUID labels, per-row review links, and policy-reconcile controls from the normal plugin assignment UI; exclude quarantined rows from normal create/update lookup; add compact progress, one manual-plan confirmation, and direct exception remediation links.
- [ ] 4.7 Add domain, authorization, controller, concurrency, reconnect, schema/credential failure, cross-tenant, aggregate-projection, and LiveView tests for automatic and one-confirmation recovery.
- [ ] 4.8 Replace the row-by-row operator runbook, deploy the corrected workflow to demo, and verify expected active assignments, service-state rows, plugin execution, automatic retries, and grouped exceptions before declaring restoration complete.
