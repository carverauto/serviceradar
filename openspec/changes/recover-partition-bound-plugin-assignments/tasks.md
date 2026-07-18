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

## 4. Zero-touch trusted recovery correction

- [x] 4.1 Add a named internal Oban worker that scans disabled unbound history in bounded keyset pages and is scheduled uniquely by the existing plugin policy scheduler.
- [x] 4.2 Restrict automatic manual recovery to approved, verified, signed, content-addressed first-party packages; leave uploaded and otherwise untrusted packages disabled.
- [x] 4.3 Reuse the guarded recovery transaction to recheck current mTLS evidence, current schema, secret references, and active conflicts, create a fresh bound assignment, preserve the source row, and converge through the immutable audit.
- [x] 4.4 Keep policy-owned rows out of the manual worker and rely on current plugin-policy and credential-rule reconcilers rather than cloning historical owner state.
- [x] 4.5 Exclude quarantined history from normal assignment lists/lookups and remove the legacy candidate table and all per-row recovery/reconciliation controls from operator workflows.
- [x] 4.6 Source the Settings release card from the deployed immutable web-ng image tag with a local-development fallback.
- [x] 4.7 Add focused core, LiveView, status-card, and Helm rendering tests for trust gating, automatic recovery, hidden history, fresh create behavior, and deployed release identity.
- [x] 4.8 Preserve empty JSON object versus array types in cross-runtime upload-signature canonicalization so correctly signed first-party packages remain eligible for trusted import and recovery.
- [x] 4.9 Give periodic first-party Wasm sync a distinct scheduled-successor uniqueness contract so the executing job cannot suppress its hourly successor and trigger minute-scale bootstrap retries.
- [ ] 4.10 Run complete Elixir and Helm quality gates, deploy the corrected workflow to demo, and verify active assignments, disabled audit history, plugin execution, absence of the legacy queue, and the displayed release version.
