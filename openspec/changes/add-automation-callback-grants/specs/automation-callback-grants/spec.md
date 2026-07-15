## ADDED Requirements

### Requirement: Automation callbacks use attenuated grants
ServiceRadar SHALL use separate opaque callback grants and MUST NOT forward a human user's normal access token or a platform/worker credential to AWX. A grant SHALL bind the initiating principal, issuance-time authorization ceiling, tenant, parent run, child execution, controller, inventory, template, immutable SCM revision/content hash, exact target set, response policy, audience, named actions, TTL, budget, idempotency, and revocation state.

Effective authority SHALL be the intersection of the immutable issuance-time ceiling, current principal membership/permissions, current run/job/target/policy/approval state, reviewed playbook declarations, and action/deployment maximum. Later expansion MUST NOT enlarge an existing grant.

#### Scenario: Platform worker dispatches an authorized grant
- **WHEN** a SystemActor or internal worker transports an already-authorized child launch
- **THEN** it can transport only the immutable grant reference and cannot expand actor, actions, targets, revision, lifetime, or budget

#### Scenario: User is promoted after issuance
- **WHEN** the initiating user gains broader permissions after mint
- **THEN** the existing grant retains its narrower issuance-time ceiling

#### Scenario: Current authority contracts
- **WHEN** the principal is disabled/deleted, loses tenant/permission, approval expires, target is quarantined, policy drifts, or the job is cancelled
- **THEN** callback use is denied, the grant is revoked, and ServiceRadar immediately attempts to cancel or terminate the AWX child
- **AND** an unconfirmed cancellation is durably recorded as `cancel_failed` or equivalent orphan-risk state without restoring callback authority

### Requirement: Logged-in profiles authorize launch and callback separately
An integrated SSH-CA launch SHALL require the logged-in profile to grant both `ansible.runs.launch` and exact RBAC permission `devices.remote_access.ssh.ca_bundle.read` before creating a run or contacting AWX. The latter authorizes callback action `remote_access.ssh_ca.bundle.read`. Neither permission SHALL imply the other, and both SHALL be rechecked before activation and use.

The CA-bundle permission SHALL be present only on the built-in administrator role by default, absent from viewer/operator defaults, and explicitly assignable to custom roles through authorized role/profile administration UI/API.

#### Scenario: User can launch but cannot read CA policy
- **WHEN** the user has `ansible.runs.launch` but lacks the CA-bundle action permission
- **THEN** ServiceRadar identifies the missing permission and does not dispatch AWX

#### Scenario: User can read CA policy but cannot launch
- **WHEN** the user has the action permission but lacks `ansible.runs.launch`
- **THEN** ServiceRadar denies launch and does not mint a grant

#### Scenario: Confirmation displays effective authority
- **WHEN** a user reviews the launch
- **THEN** the UI shows `ansible.runs.launch`, `devices.remote_access.ssh.ca_bundle.read`, action, target scope, revision, policy/approval, TTL, and budget without exposing a bearer

#### Scenario: Profile administrator grants CA distribution
- **WHEN** an authorized administrator adds `devices.remote_access.ssh.ca_bundle.read` to a custom role
- **THEN** only principals assigned that role become eligible for future grants and existing grants do not expand retroactively

### Requirement: Integrated grants activate only after exact AWX binding
ServiceRadar SHALL create the parent run, child execution, immutable snapshot, and unusable pending grant before dispatch. It SHALL atomically verify and bind the returned controller-local AWX job ID, controller, inventory, template, revision, exact non-empty limit, approved base credentials plus exactly one bound ephemeral callback credential, and target count before activation. It SHALL keep the grant pending until authenticated job-host summaries match the complete immutable AWX host-ID/name set. The reviewed helper SHALL read AWX's system-provided positive integer `JOB_ID` directly from the execution environment, include it in the request, and require the response to echo it. The custom credential, surveys, inventory, and ordinary variables MUST NOT inject or override `JOB_ID`.

#### Scenario: Callback races activation
- **WHEN** the execution environment calls while the grant is pending
- **THEN** it receives only a sanitized retryable pending response without data or budget consumption

#### Scenario: Dispatch is ambiguous
- **WHEN** ServiceRadar cannot prove which AWX job accepted a timed-out launch
- **THEN** it revokes the grant and requires a newly authorized child rather than retrying with the same bearer

#### Scenario: Job is relaunched or copied
- **WHEN** AWX starts a relaunch/copy without the exact active child/job binding
- **THEN** the old grant is unusable

#### Scenario: Copied job retains the ephemeral callback credential
- **WHEN** a copied or relaunched job presents the old bearer and idempotency key but AWX supplies its distinct runtime `JOB_ID`
- **THEN** ServiceRadar denies the request before response release or budget consumption

#### Scenario: Full host scope is not materialized yet
- **WHEN** the accepted job has not produced one authenticated host-bound summary for every immutable target
- **THEN** the callback remains pending and receives no CA or principal policy

### Requirement: Target and response policy binding is mandatory
Every integrated grant SHALL bind a normalized immutable snapshot/hash of exact device UIDs, AWX host IDs/names/addresses, controller, inventory, template, revision, CA key set, policy version, and per-target account/principal mapping. Requests MUST NOT select or replace those values, and one target losing authorization SHALL deny the whole child retrieval.

#### Scenario: Target policy changes before retrieval
- **WHEN** current target membership, approval, CA policy, or principal mapping differs from the issuance snapshot
- **THEN** no partial or broadened response is returned and a new authorization is required

#### Scenario: Cross-target mapping is substituted
- **WHEN** a job requests or relabels another target's mapping
- **THEN** ServiceRadar denies the callback and records scoped misuse

### Requirement: Callback consumption is atomic and replay bounded
The initial read-only CA/policy action SHALL allow one successful logical read per child/policy partition. Reauthorization, idempotency reservation, response commit/reference, budget transition, and success audit SHALL be atomic. Same-key retry MAY return the byte-identical response after reauthorization; a different key or changed payload MUST be denied after consumption. Authentication failures SHALL not consume success budget and SHALL use separate throttling.

#### Scenario: Two workers race first use
- **WHEN** different idempotency keys concurrently use a one-read grant
- **THEN** exactly one commits success and the other is denied

#### Scenario: Response is lost
- **WHEN** the successful caller retries the same key after losing the response
- **THEN** ServiceRadar rechecks current authority and may return the committed byte-identical response without another budget use

#### Scenario: Authority is revoked after success
- **WHEN** the same key retries after current authority is revoked
- **THEN** cached response replay is denied

### Requirement: Tokens use a reviewed AWX secret boundary
The bearer SHALL exist in a single-resolution encrypted launch envelope with authenticated tenant/command/child/controller/inventory/template/dispatch-agent/expiry binding and an ephemeral reviewed AWX custom credential environment/header injector. Survey answers, ordinary `extra_vars`, inventory/group/host vars, facts, artifacts, task files, and managed-host state MUST NOT carry it.

The authorized dispatcher, AWX credential-decryption path, selected execution environment, and reviewed helper are explicit transient bearer-handling boundaries.

#### Scenario: AWX retention surfaces are inspected
- **WHEN** job API/detail, stdout/events, relaunch/copy, facts, artifacts, analytics, support bundles, failure logs, or backups are inspected
- **THEN** no plaintext bearer, bearer hash, envelope plaintext, or replayable authorization is exposed

#### Scenario: Custom credential binding is absent
- **WHEN** a template lacks the reviewed injector or would expose the token as an ordinary variable
- **THEN** ServiceRadar rejects binding/launch

#### Scenario: Managed host runs the role
- **WHEN** the execution environment applies enrollment
- **THEN** the host receives only its public CA/principal files and no callback token/environment value

#### Scenario: Runtime job identity is read
- **WHEN** the helper builds its callback request
- **THEN** it reads `JOB_ID` from AWX's system runtime environment and not from the ephemeral custom credential or any playbook-controlled value

### Requirement: Callback key custody is least privilege by runtime
The web/API runtime SHALL be the only ServiceRadar workload that receives the callback bearer HMAC keyring and canonical callback origin. The core runtime MAY receive the launch-envelope key and non-secret reviewed AWX/response-policy contract for envelope resolution and internal continuation. Internal result, cleanup, and recovery operations MUST use persisted authority without the bearer HMAC keyring. Agent gateways MUST receive none of this callback custody material. A disabled deployment MUST NOT project callback key files into any workload.

#### Scenario: Internal cleanup runs on core
- **WHEN** core coordinates or recovers an already-authorized callback child
- **THEN** it uses secret-free internal lifecycle adapters and cannot issue or consume a callback bearer

#### Scenario: Callback feature is disabled during an upgrade
- **WHEN** an installation uses an older external Secret without callback keys and leaves callbacks disabled
- **THEN** core, web, and gateway render without callback-key environment variables, mounts, or volumes

### Requirement: Callback transport is canonical and bounded
Integrated callbacks SHALL use a server-selected canonical HTTPS origin with CA/hostname verification. User, catalog, playbook, redirect, proxy, or response input MUST NOT change the credential destination. The helper SHALL disable redirects and credential forwarding, bound method/time/size, validate content type/schema, and expose sanitized statuses.

#### Scenario: Endpoint redirects
- **WHEN** the canonical endpoint redirects to another origin or port
- **THEN** the helper refuses and does not forward the bearer

#### Scenario: Response violates its contract
- **WHEN** TLS, content type, schema, or size validation fails
- **THEN** the helper fails closed without distributing partial data

### Requirement: Callback actions are reviewed security contracts
Every action SHALL declare schema, security tier/effect, sensitivity, target binding, bearer/proof-of-possession rule, principal types, approval, TTL/budget/size, idempotency, audit, and deployment maximum. Catalog metadata SHALL pin immutable SCM content and exact AWX bindings. This change SHALL register only read-only internal `remote_access.ssh_ca.bundle.read`; public CA keys are non-secret, while target/principal mappings remain target-scoped internal data.

#### Scenario: Playbook requests an undeclared action
- **WHEN** a revision requests an action/schema outside its reviewed metadata
- **THEN** binding, minting, and callback use are denied

#### Scenario: Future action returns secrets or mutates
- **WHEN** an action would return a secret, mutate, sign, or mint credentials
- **THEN** it requires a separate approved security proposal and stronger proof of possession where appropriate

#### Scenario: AWX runs another revision
- **WHEN** the accepted job cannot prove the approved SCM revision/content hash
- **THEN** the callback remains unavailable and the grant is revoked

### Requirement: Service-principal ceilings are fixed and owned
Unattended automation SHALL use an explicit owned service principal/workload identity that itself holds `ansible.runs.launch` and `devices.remote_access.ssh.ca_bundle.read`, with fixed tenant, actions, catalog/template/revision set, target ceiling, TTL/budget, owner, expiry, rotation, and disable controls. Wildcards, cross-tenant selection, self-expanding targets, and worker-inherited authority SHALL be forbidden; workload OIDC or mTLS SHOULD be preferred.

#### Scenario: Service principal lacks one required permission
- **WHEN** a schedule principal lacks either `ansible.runs.launch` or `devices.remote_access.ssh.ca_bundle.read`
- **THEN** ServiceRadar does not create the child execution or mint a callback grant

#### Scenario: Service automation selects a new target
- **WHEN** a schedule includes a target outside its configured ceiling
- **THEN** grant minting fails instead of expanding scope

#### Scenario: Service principal is retired
- **WHEN** the owner disables it or it expires
- **THEN** outstanding grants are revoked and new grants cannot be minted

### Requirement: Callback lifecycle audit is durable and secret free
ServiceRadar SHALL durably audit by grant ID: mint/pending, envelope resolution, dispatch outcome, AWX binding/activation, callback allow/deny/pending/replay, budget, response fingerprint/policy version, revoke/expire, credential deletion, cleanup, and misuse. Audit MUST NOT contain the token, token hash, envelope plaintext, response body, or secrets. Successful response release SHALL fail closed unless authorization, idempotency, budget, and audit commit atomically.

#### Scenario: Success cannot be audited
- **WHEN** the durable consume/audit transaction cannot commit
- **THEN** ServiceRadar returns no response and prevents unsafe reuse

#### Scenario: Revoked bearer is replayed
- **WHEN** a revoked/expired bearer is presented
- **THEN** ServiceRadar denies it, records only non-secret grant ID/reason, throttles abuse, and raises the configured signal
