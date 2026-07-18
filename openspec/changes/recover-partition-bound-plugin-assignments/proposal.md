# Change: Recover partition-bound plugin assignments safely

## Why

The partition-binding migration correctly disabled legacy plugin assignments that had no immutable proof of the edge partition that originally received them. The current plugin package UI has no way to show the authenticated partition, distinguish an unbound legacy row from a normal disabled assignment, or safely reapprove it. As a result, operators see missing services and an apparent assignment form that cannot recover the affected rows.

## What Changes

- Show the server-authenticated partition for an agent selected in the plugin assignment UI, without adding a user-editable partition selector.
- Add an explicit, audited reapproval flow for manually managed legacy assignments that creates a new partition-bound assignment only after the server resolves current mTLS control-session evidence.
- Keep the historical unbound assignment disabled as audit history; do not mutate it into a live assignment or infer its partition from agent metadata.
- Route policy-owned legacy assignments back through their authoritative policy or credential-rule materializer instead of allowing a manual clone.
- Require the initiating user to be authorized for the requested assignment or policy reconciliation, preserve secret *references* only, and fail closed when current identity evidence, package approval, schema validation, or conflict checks fail.
- Provide a tenant-scoped review list for quarantined legacy assignments so operators can find each affected agent and package without a bulk re-enable action or a default-partition assumption.
- Surface only a redacted, durable policy-recovery status in the package UI and refresh it while reconciliation is queued or running; recovery-request payloads, principals, owner identifiers, and replacement identifiers remain internal.
- Make credential-rule recovery requirements explicit in the UI: it needs both plugin-assignment and credential-management authority, while the control plane remains the final authorization point.

## Impact

- Affected specs: `wasm-plugin-system`, `plugin-configuration-ui`, `ash-authorization`
- Affected code: plugin assignment domain/actions, authenticated edge-session lookup, credential-rule materializer, plugin package LiveView/API, durable recovery-request status projection, assignment audit/history, and operator documentation
- Operational impact: legacy assignments remain quarantined until an authorized operator explicitly reapproves manual rows or reconciles the owning policy; no direct SQL re-enable procedure is introduced.
