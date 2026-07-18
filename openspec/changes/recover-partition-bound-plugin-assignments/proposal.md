# Change: Recover partition-bound plugin assignments safely

## Why

The partition-binding migration correctly disabled legacy plugin assignments that had no immutable proof of the edge partition that originally received them. The first recovery implementation preserved that boundary, but exposed the migration as a row-by-row operator queue. It repeats historical rows, displays package UUIDs instead of recognizable plugin names, mixes recovery controls into the normal assignment editor, and requires one click per agent and package even when a current policy or credential rule is already authoritative.

That is an internal data-repair workflow, not an acceptable product workflow. Partition safety does not require operators to understand historical storage details or manually replay controller-owned desired state. Recovery should be automatic wherever current authority and identity can be proven, require at most one tenant-scoped confirmation for remaining compatible manual intent, and surface only grouped exceptions that need a human decision.

## What Changes

- Automatically reconcile policy- and credential-rule-owned legacy assignments from their current authoritative owner. The controller deduplicates historical rows into one logical desired assignment, retries on agent reconnect and owner/package changes, and requires no per-row operator action.
- Add a tenant-scoped recovery plan for compatible manually managed legacy assignments. One authorized confirmation adopts the current authenticated principal for every eligible item in the plan; the server rechecks mTLS evidence, package approval, schema compatibility, authorization, and conflicts for each item at commit time.
- Automatically recover a manual assignment without confirmation only when immutable principal-continuity evidence independently binds the historical intent to the current authenticated principal. Current agent metadata, a matching UID, or a `default` partition assumption is not continuity evidence.
- Keep the historical unbound assignment disabled as audit history; do not mutate it into a live assignment or infer its partition from agent metadata.
- Treat an operator's normal create action as fresh intent. Quarantined history must never be selected as the current assignment, block remove-and-recreate, or redirect a normal create into legacy recovery.
- Preserve secret *references* only and fail closed per item when current identity evidence, package approval, schema validation, current owner authority, or conflict checks fail.
- Replace the legacy candidate queue with a compact recovery summary and a grouped exception view. Use plugin names and affected-agent counts, keep raw identifiers in technical detail only, and keep historical recovery rows out of the normal assignment editor.
- Distinguish waiting states from actionable exceptions: offline agents retry automatically, while schema incompatibility, invalid credential policy, unsupported owners, authorization denial, and assignment conflicts explain the single remediation that is actually required.
- Surface only redacted aggregate progress and exception state. Recovery-request payloads, principals, owner identifiers, replacement identifiers, and raw recovery-audit rows remain internal.
- Remove the row-by-row recovery runbook and document the automatic controller, one-time manual adoption plan, fail-closed checks, and exception remediation instead.

## Impact

- Affected specs: `wasm-plugin-system`, `plugin-configuration-ui`, `ash-authorization`
- Affected code: plugin assignment recovery planner, authenticated edge-session lookup, policy and credential-rule reconcilers, plugin package LiveView/API, durable aggregate status projection, assignment audit/history, and operator documentation
- Operational impact: controller-owned assignments recover automatically; compatible manual assignments require no more than one tenant-scoped confirmation unless immutable continuity permits automatic recovery; only blocked exceptions remain visible. No direct SQL re-enable procedure or inferred default partition is introduced.
