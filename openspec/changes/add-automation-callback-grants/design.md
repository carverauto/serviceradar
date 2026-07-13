## Context

An AWX launch is asynchronous: ServiceRadar knows the local run and exact requested target set before dispatch, but learns the controller-local AWX job ID only from the launch response. A callback grant cannot be safely bound by minting it after the job starts, nor can it be active before the returned job is verified. The bearer also necessarily crosses ServiceRadar dispatch, AWX encrypted credential storage/decryption, and the execution environment, so those components must be modeled explicitly instead of claiming the secret is never visible.

The initial callback returns a public SSH CA plus target-scoped internal principal-policy data. It returns no secret, but the target mapping still requires exact authorization and redaction. This does not justify a general API tunnel or a bearer contract for secrets and mutations.

## Goals / Non-Goals

### Goals

- Preserve the initiating principal as the privilege ceiling across asynchronous automation.
- Make integrated callback authentication automatic for operators without forwarding their normal token or requiring a general API key.
- Bind authorization to immutable reviewed code, controller/template context, and exact targets.
- Make retries deterministic without allowing replay or extra budget.
- Keep callback credentials out of managed hosts and ordinary ServiceRadar/AWX data surfaces.
- Provide a reusable action/schema author contract for future separately reviewed actions.

### Non-Goals

- Do not expose arbitrary ServiceRadar APIs through callback grants.
- Do not authorize a secret-returning, mutating, signing, credential-minting, or reusable action in this change.
- Do not use surveys or ordinary `extra_vars` as secret storage.
- Do not let SystemActor, an AWX credential, or a platform worker expand user authority.
- Do not solve AWX inventory/hostname identity in this change; it is a prerequisite.

## Decisions

### Decision: Authority is issuance ceiling intersected with current state

Effective authority is:

```text
issuance-time principal permissions, tenant, target, approval, action, and deployment ceiling
  INTERSECT current enabled principal membership and permissions
  INTERSECT current run, AWX job, target, approval, and policy state
  INTERSECT reviewed playbook action/schema declarations and immutable revision
  INTERSECT current action-registry and deployment maximum
```

Later promotion, target additions, policy broadening, or deployment broadening cannot enlarge an existing grant. Deletion, disablement, permission loss, approval expiry, target quarantine, revision drift, or job cancellation denies/revokes and triggers immediate best-effort AWX child cancellation. If cancellation cannot be confirmed, ServiceRadar records durable `cancel_failed`/orphan-risk state and keeps the callback grant revoked.

An integrated SSH-CA enrollment launch checks `ansible.runs.launch` and exact permission `devices.remote_access.ssh.ca_bundle.read` before creating run records or contacting AWX, again before activation, and again on callback use. Neither permission implies the other. The permission is added to RBAC catalog and role/profile UI/API, granted only to the built-in administrator role by default, absent from viewer/operator defaults, and explicitly assignable to custom roles by an authorized profile administrator. Scheduled service principals must independently hold both permissions within their immutable ceiling.

### Decision: Use pending-to-active AWX binding

ServiceRadar transactionally creates the parent run, child execution, immutable launch snapshot, and hashed pending grant. The launch envelope contains a reference to that pending grant. When AWX returns, ServiceRadar verifies the controller, inventory, template, SCM revision, exact non-empty limit, target count, and the accepted credential set: every approved base credential plus exactly one distinct bound ephemeral callback credential. It then binds the returned job ID but keeps response authority pending until authenticated job-host summaries equal the complete immutable AWX host-ID/name set. The public integrated entrypoint creates one controller-local host-bound event per limited inventory host before its callback task, so this proof does not contact managed targets or depend on hostname/address inference. A callback racing either proof receives only a retryable `grant_pending` result.

AWX supplies a positive integer `JOB_ID` in the running job environment. The helper reads it directly, includes it in the exact request body, and validates the echoed value. The reviewed custom credential does not define `JOB_ID`, and exact accepted-credential proof prevents an extra custom credential from substituting it. A copied or relaunched job necessarily receives a different AWX job ID, so possession of retained encrypted callback material cannot authorize a response for the original child.

A timeout with an unknown launch result is `dispatch_ambiguous`: revoke the grant, delete/detach the ephemeral credential, and require a newly authorized child. AWX relaunch/copy never reuses an old grant.

### Decision: Make target and response policy immutable

Every grant includes a normalized snapshot/hash of canonical device UIDs, AWX host IDs/names/addresses, controller, inventory, template, approved SCM revision/content hash, CA key set, policy version, and per-target local-account/opaque-principal mapping. The endpoint derives the response from the snapshot; requests cannot select targets, CA keys, or principals. Children are partitioned by compatible policy or receive a target-keyed response, and one target losing authorization denies the whole child retrieval.

### Decision: Use atomic one-read idempotency

The initial action permits one successful logical read per child/policy partition. Reauthorization, idempotency reservation, response commit/reference, budget transition, and success audit are atomic. A retry with the same idempotency key may receive the committed byte-identical response after current-state reauthorization; different keys lose once budget is consumed. Authentication failures do not consume success budget but use separate abuse throttles and alerts.

### Decision: Use a reviewed AWX custom credential boundary

The random bearer is placed in a single-resolution encrypted envelope whose authenticated data binds tenant, command, child, controller, inventory, template, dispatch agent, and expiry. Dispatch resolves it into an ephemeral reviewed AWX custom credential environment/header injector. The injector carries callback material and immutable request fields but never AWX's system `JOB_ID`. Outside the reviewed local helper invocation, it is never a survey answer, ordinary `extra_vars`, inventory/host/group var, persisted task/event output, fact, artifact, or target file.

Runtime custody is split by function. Only the web/API release receives the HMAC keyring used to issue and verify callback bearers, plus the canonical callback origin. The core release receives only the launch-envelope key and the non-secret AWX credential/response-policy contract needed for authenticated envelope resolution, current-authority checks, result coordination, and recovery. Internal continuation adapters use persisted authority and never require bearer signing material. Agent gateways only attest and broadcast command ingress and receive no callback key, origin, response-policy, or AWX credential material. Disabled deployments project none of these callback keys, preserving upgrades that use an older external Secret.

The dispatcher, AWX controller credential-decryption path, selected execution-environment process, and reviewed helper are trusted transient bearer handlers. Acceptance tests inspect AWX job detail/API, stdout/events, relaunch/copy, facts, artifacts, analytics, support bundles, failure logs, and backups. Expiry/revocation keeps a restored encrypted credential inert.

The controller's own AWX API tokens are a different boundary and are split by purpose. The sync principal can perform only health/catalog/inventory reads. The execution principal can launch, observe, reconcile, and cancel only reviewed jobs. Ephemeral custom-credential create/fetch/delete use the callback principal only; launch still uses execution. The callback reference may intentionally equal execution. Runtime callback privilege is confined to Credential Admin in a dedicated empty AWX organization such as `ServiceRadar Ephemeral`; it never receives Credential Admin in the organization containing production or operator credentials. A distinct callback principal is supported only when AWX role wiring also proves the execution principal can use each generated credential. None of these AWX controller tokens enters the launch envelope, custom credential, execution environment, or playbook.

### Decision: Register actions as security contracts

Each action declares versioned request/response schemas, security tier/effect, sensitivity, target binding, bearer versus proof-of-possession rule, principal types, approval, TTL/budget/size limits, idempotency, audit, and deployment maximum. Reviewed catalog metadata pins the immutable SCM commit/content hash and exact AWX project/template/inventory/credential binding.

This change registers only read-only internal `remote_access.ssh_ca.bundle.read`, whose public key material is non-secret but whose target/principal mapping remains target-scoped. Any secret-returning, mutating, signing, or credential-minting action needs another OpenSpec security review and should use workload OIDC, mTLS, or proof of possession instead of this bearer-only boundary.

### Decision: Use canonical bounded transport and secret-free audit

The callback origin is server-selected canonical HTTPS with CA and hostname verification. User/catalog/playbook input, redirects, proxies, or response content cannot change the credential destination. The helper disables redirects and unintended proxy credential forwarding, bounds method/time/size, validates content type/schema, and returns sanitized statuses.

Audit uses grant ID, never token/hash, and covers mint, activation, envelope resolution, dispatch, callbacks, replay, budget, response fingerprint/policy version, revoke/expire, credential cleanup, and misuse. Response digests are audit fingerprints, not authenticity proofs without a separately defined pinned signature key. A successful response fails closed if durable consume/audit commit fails.

## Risks / Trade-offs

- AWX and the execution environment become explicit transient bearer boundaries. Short TTL, one-read budget, exact binding, custom credential injection, egress restriction, and revocation limit impact.
- Denying an entire child on one target's policy drift can require a new smaller launch, but avoids partial cross-target policy confusion.
- Pending activation requires bounded helper retry, but closes the circular AWX-job binding gap.
- This generic model is deliberately conservative; stronger future actions will require proof of possession and separate review.

## Migration and Rollout

1. Reconcile/archive the delivered Ansible baseline, then land `harden-ansible-awx-targeting` with collision-safe child execution, exact target snapshots, secret references, and callback-action permission gates.
2. Add grant/action/audit resources secure-off, then canonical HTTPS deployment configuration.
3. Add custom credential type/binding validation and envelope delivery.
4. Register only the public CA-bundle action and bind the reviewed enrollment revision/template.
5. Test denial, replay, ambiguous launch, retention surfaces, supply-chain drift, and current authorization contraction.
6. Enable for one canary child, then bounded enrollment partitions.

Rollback disables callback-enabled bindings, revokes outstanding grants, deletes ephemeral AWX credential instances, and leaves ordinary non-callback Ansible launches unchanged.
