## Context

The partition migration set legacy plugin assignments to `enabled = false` and
`partition_id = NULL` because inventory metadata could not prove their historical
partition. The initial recovery implementation preserved that security boundary
but rendered every row as a separate task. Duplicate rows, obsolete policy rows,
and already-replaced assignments therefore remained visible even though none of
them represented current operator work.

New assignments already derive their partition from
`AgentCommandBus.resolve_control_session_evidence/1`. First-party Wasm packages
also carry approval, verification, signature, content hash, and object-store
identity. Those are sufficient controls for a narrow automatic migration of
compatible first-party manual intent without allowing arbitrary uploaded code or
caller-selected routing.

## Goals / Non-Goals

### Goals

- Restore compatible trusted first-party manual assignments without browser work.
- Preserve fresh mTLS partition binding and fail closed when the agent is offline
  or identity evidence is inconsistent.
- Keep current policy and credential-rule reconcilers authoritative.
- Keep migration history available internally while removing it from normal
  assignment and operator workflows.
- Make retries bounded, idempotent, auditable, and safe under repeated scheduling.
- Display the actually deployed ServiceRadar release version.

### Non-Goals

- Do not mutate or re-enable a legacy row in place.
- Do not assume `default`, trust mutable inventory partition metadata, or accept a
  caller-supplied partition.
- Do not automatically recover uploaded, unsigned, unverified, or non-first-party
  packages.
- Do not clone historical policy configuration or use a legacy policy row as
  controller authority.
- Do not turn deferred rows into a replacement recovery dashboard. Operators can
  create a fresh assignment or correct the current authoritative policy normally.

## Decisions

### Trusted first-party manual history is recovered automatically

The periodic worker reads a bounded keyset page of disabled, unbound legacy rows
using a named internal actor. It considers only `source = :manual` rows. Before
and inside the transaction the package must still be:

- `status = :approved`;
- `source_type = :first_party`;
- `verification_status = "verified"`;
- backed by a nonempty content hash and Wasm object key; and
- accompanied by nonempty signature evidence.

The recovery transaction locks the historical row, resolves current mTLS control
session evidence for its exact agent UID, validates the old non-secret parameters
against the current package schema, preserves references rather than secret
values, and checks for an enabled assignment conflict in the resolved partition.
It then creates a new assignment through the ordinary partition-binding action.
The old row remains disabled and unbound.

Uploaded or otherwise untrusted packages are deliberately deferred. This permits
zero-touch migration only for release-controlled artifacts while keeping manual
plugin upload and approval a separate trust decision.

### Recovery is bounded and convergent

The existing scheduler enqueues the worker every five minutes. Each job processes
at most 100 rows and schedules the next keyset page when more rows exist. Oban
uniqueness prevents overlapping base sweeps.

The immutable recovery audit is the idempotency boundary. A recovered audit
returns its existing replacement. Terminal schema, trust, and conflict outcomes
are not retried continuously; transient identity or persistence failures remain
eligible for a later sweep. Package trust and all mutable safety conditions are
checked again at execution time.

### Policies recover from current authority, not history

The automatic manual worker ignores `source = :policy`. Existing plugin target
policy and credential-rule reconcilers already recompute current desired state,
targets, configuration, credentials, and package selection. They may create a
fresh assignment only under their ordinary narrow controller authority and fresh
mTLS evidence.

A missing, disabled, unsupported, or no-longer-matching owner produces no new
assignment. The historical row neither authorizes work nor supplies stale
configuration. This is normal desired-state reconciliation and requires no
browser event.

### Legacy rows are audit history, not product navigation

All normal assignment list and lookup paths exclude rows that are both disabled
and partition-unbound. The package editor consequently shows only current bound
assignments, and a fresh create cannot be redirected into an immutable legacy
update. The Plugins index no longer enumerates a legacy candidate page.

Raw history and recovery audits remain available through restricted internal
contexts for diagnosis. The ordinary UI contains no per-row review, reapproval,
or policy reconciliation actions. A deferred row does not block a fresh manual
assignment using current configuration.

### Release status comes from deployment identity

Helm injects `SERVICERADAR_RELEASE_VERSION` from the same immutable image tag used
for the web-ng container. The status card strips an optional leading `v` and uses
that value before consulting imported agent-release data. Local development may
fall back to the database when the deployment variable is absent.

## Risks / Trade-offs

- Historical manual configuration may no longer satisfy a new schema. It remains
  disabled rather than being silently rewritten.
- An offline agent cannot provide current partition evidence. The worker retries
  later without asking the operator to process a queue.
- A current assignment may already supersede the old intent. Conflict checks keep
  it untouched and the legacy row remains hidden history.
- The worker can create a short post-upgrade burst. Bounded pages, scheduler
  uniqueness, audit idempotency, and terminal outcomes limit the load.

## Migration Plan

1. Deploy the bounded worker, trust allowlist, current-state checks, and UI filter.
2. Run the worker after scheduler startup and let current policy reconcilers
   converge controller-owned assignments.
3. Verify active replacement assignments, disabled source history, and plugin
   execution in demo.
4. Confirm the Plugins UI contains no legacy work queue and reports the deployed
   image release.

Rollback disables newly created replacement assignments through ordinary
assignment controls. Historical rows are never modified or inferred.
