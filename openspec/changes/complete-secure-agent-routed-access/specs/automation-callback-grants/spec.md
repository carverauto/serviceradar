## ADDED Requirements

### Requirement: Automation callbacks use attenuated delegated grants
ServiceRadar SHALL authorize automation callbacks with separate opaque delegated grants and MUST NOT forward a human user's normal browser/API token to AWX, Ansible, plugins, or managed targets. An integrated grant SHALL bind the initiating actor or service principal, tenant/deployment, parent run, local child execution, controller, inventory, job template, immutable SCM revision and content hash, exact canonical-device/AWX-host target set, response policy snapshot, audience, named actions, TTL, request budget, and revocation state.

The maximum authority of a grant SHALL be the intersection of the initiating principal's issuance-time permission/tenant/target/approval snapshot, that principal's current enabled membership and permissions, the current target policy and approval, the reviewed playbook declarations, and the deployment/action maximum. Later RBAC expansion MUST NOT enlarge an existing grant. A system worker, platform credential, AWX credential, or grant issuer MUST NOT add authority that the initiating principal did not hold at issuance.

#### Scenario: Integrated Ansible launch needs a callback
- **WHEN** an authorized playbook revision declares a required ServiceRadar callback action
- **THEN** ServiceRadar mints a new grant with only that named action and immutable execution/target/policy bindings without exposing the actor's login token

#### Scenario: Grant is used for another API or target
- **WHEN** the bearer is presented to an endpoint, action, target set, playbook revision, controller, inventory, or template outside its immutable binding
- **THEN** ServiceRadar rejects the request without falling back to the initiating user's broader permissions

#### Scenario: User lacks the declared callback permission
- **WHEN** a user can launch an Ansible job but lacks the permission mapped to one of the playbook's declared callback actions
- **THEN** ServiceRadar refuses to mint that action and does not substitute a system or platform credential

#### Scenario: User receives broader permission after issuance
- **WHEN** the initiating user gains a broader role after a grant was issued
- **THEN** the existing grant retains its issuance-time ceiling and cannot use the newly granted authority

#### Scenario: Current authority contracts
- **WHEN** the initiating principal is disabled or deleted, loses tenant membership or permission, the target policy changes, or a required approval expires
- **THEN** every affected callback is denied and the entire not-yet-completed child execution fails closed without partially widening or retargeting the batch

#### Scenario: Internal worker dispatches the job
- **WHEN** an internal worker or SystemActor performs queue or transport work for an already-authorized run
- **THEN** it may transport only the immutable attenuated grant reference and cannot expand its actions, targets, lifetime, request budget, policy snapshot, or initiating principal

### Requirement: Integrated grants bind safely to AWX jobs
ServiceRadar SHALL create the parent run, local child execution, immutable launch snapshot, and pending callback grant before dispatching an integrated AWX job. The grant SHALL remain unusable while pending. After AWX accepts the launch, ServiceRadar SHALL atomically bind the returned controller-local AWX job ID to the child execution and activate the grant. A callback that races activation SHALL receive only a bounded retryable pending response.

#### Scenario: AWX accepts a launch
- **WHEN** AWX returns one unambiguous job ID for the snapshotted controller, inventory, template, SCM revision, and target limit
- **THEN** ServiceRadar atomically records that job binding and changes the grant from pending to active

#### Scenario: Launch acceptance is ambiguous
- **WHEN** dispatch times out or fails after ServiceRadar cannot prove whether AWX accepted the job
- **THEN** ServiceRadar revokes the pending grant, marks the child execution dispatch-ambiguous, and does not activate or reuse the bearer

#### Scenario: Callback arrives before activation
- **WHEN** the AWX execution environment calls while its grant is still pending
- **THEN** the endpoint returns a sanitized retryable pending result without consuming the action budget or revealing binding details

#### Scenario: AWX relaunch or copied job
- **WHEN** AWX relaunches, copies, or otherwise starts a job that does not have the exact active ServiceRadar child-execution/job binding
- **THEN** the original grant is unusable and a newly authorized ServiceRadar launch is required

### Requirement: Initiating profiles authorize both launch and callback actions
An interactive integrated launch SHALL require the logged-in user's current ServiceRadar profile to grant both the Ansible playbook launch permission and every callback-action permission declared by the reviewed playbook. For SSH-CA enrollment this means `ansible.runs.launch` and the permission mapped to `remote_access.ssh_ca.bundle.read`, in addition to target policy and any required approval. Neither permission SHALL imply the other. ServiceRadar SHALL check the complete permission set before creating run records or contacting AWX and SHALL recheck it when activating and using the callback grant.

#### Scenario: User can launch Ansible but cannot read the CA bundle
- **WHEN** the logged-in user has `ansible.runs.launch` but lacks the permission mapped to `remote_access.ssh_ca.bundle.read`
- **THEN** ServiceRadar explains that the remote-access CA permission is missing and does not create or dispatch an AWX job

#### Scenario: User can read the CA bundle but cannot launch Ansible
- **WHEN** the logged-in user has the CA-bundle permission but lacks `ansible.runs.launch`
- **THEN** ServiceRadar denies the playbook launch and does not mint a callback grant

#### Scenario: Required permission is revoked while pending
- **WHEN** either required profile permission is revoked after confirmation but before callback consumption
- **THEN** ServiceRadar denies and revokes the callback grant and cancels or terminates the child execution where possible

#### Scenario: Confirmation displays effective authority
- **WHEN** a user reviews a callback-enabled playbook launch
- **THEN** the UI shows the required launch permission, named callback actions and mapped permissions, target scope, policy/approval requirements, TTL, and request budget without exposing a token

### Requirement: Callback APIs reauthorize every request
The automation callback API SHALL validate the hashed bearer, pending/active state, issuance-time ceiling, current actor/service authorization, run/execution/AWX-job/playbook/target/policy binding, named action, audience, expiry, request budget, and revocation on every request. The initial registry SHALL expose only the read-only public action `remote_access.ssh_ca.bundle.read`.

#### Scenario: Initiating user loses permission
- **WHEN** the user's remote-access CA distribution permission is removed before the playbook fetches the CA bundle
- **THEN** the callback is denied even though the opaque token has not reached its expiry

#### Scenario: Policy changes after grant creation
- **WHEN** the CA policy version, target principal mapping, approved playbook revision, target membership, or required approval differs from the immutable grant snapshot
- **THEN** ServiceRadar denies the callback rather than returning data selected from newer or broader policy

#### Scenario: Cross-target principal substitution
- **WHEN** a caller requests or relabels one target's principal mapping for another target in the same fleet job
- **THEN** the server derives the response from the immutable target-keyed snapshot and rejects the substitution

### Requirement: Callback consumption is atomic and replay safe
Each action SHALL define an idempotency and request-budget policy. For the initial one-read action, ServiceRadar SHALL atomically allow one successful logical request per child execution and target-policy partition. The same idempotency key MAY receive the cached byte-identical response after a lost response without consuming another use; a different key or payload after successful consumption MUST be rejected. Authentication failures SHALL not consume the action budget but SHALL be independently rate limited and audited.

#### Scenario: Concurrent first use
- **WHEN** two different idempotency keys concurrently present the same active one-read grant
- **THEN** exactly one request consumes the grant and the other is rejected as already consumed

#### Scenario: Response is lost
- **WHEN** the authorized client retries the same request with the same idempotency key after ServiceRadar committed use but the response was lost
- **THEN** ServiceRadar may return the cached byte-identical response and digest without granting another logical use

#### Scenario: Payload changes on retry
- **WHEN** a used idempotency key is replayed with different action inputs or target-policy context
- **THEN** ServiceRadar rejects the replay and records a misuse event

### Requirement: Callback tokens use a reviewed AWX secret boundary
Plaintext callback grants SHALL be generated into a short-lived encrypted launch envelope whose additional authenticated data binds the command, tenant, controller, inventory, template, child execution, and selected dispatch agent. The envelope SHALL be single-resolution and SHALL be revoked on terminal, cancelled, failed, or ambiguous dispatch.

Integrated jobs SHALL inject the resolved token only through a reviewed AWX custom credential type using an environment variable or authorization header. Survey fields, ordinary `extra_vars`, inventory variables, facts, artifacts, and managed-host variables/files MUST NOT carry the token. ServiceRadar's dispatch component, the AWX controller/credential store, and the selected execution environment are explicit trusted bearer-handling boundaries for this read-only action; a bearer is necessarily transiently visible within those components.

#### Scenario: Run history or AWX job data is viewed
- **WHEN** an operator inspects ServiceRadar run history, AWX job details/API, stdout/events, relaunch/copy data, fact cache, artifacts, support bundles, analytics, failure logs, or retained controller backups
- **THEN** no callback bearer, bearer hash, encrypted envelope plaintext, or replayable authorization value is exposed

#### Scenario: Command is persisted or retried
- **WHEN** an AWX launch command is queued, persisted, retried, or inspected
- **THEN** it contains only an opaque single-use envelope reference and public launch snapshot, not the plaintext callback token

#### Scenario: Custom credential binding is absent
- **WHEN** a candidate job template lacks the reviewed ServiceRadar callback custom credential or would expose it as an ordinary variable
- **THEN** ServiceRadar rejects the binding or launch

#### Scenario: Managed host runs the role
- **WHEN** the AWX execution environment retrieves the bundle and applies the enrollment role
- **THEN** managed hosts receive only their public CA/principal files and never receive the callback token or its custom-credential environment variable

### Requirement: Callback transport is server selected and bounded
Integrated callbacks SHALL use a server-selected canonical HTTPS origin with CA and hostname verification. Catalog entries, browsers, playbook inputs, redirects, proxies, or response data MUST NOT override the callback origin, scheme, host, port, or credential destination. The helper SHALL disable credential forwarding across redirects, apply bounded connection/read timeouts and response sizes, require the registered content type/schema, and expose only sanitized pending, denied, expired, consumed, rate-limited, and unavailable errors.

Response digests SHALL be treated as integrity/audit fingerprints unless the response also carries a signature verifiable under a separately specified trusted verification key.

#### Scenario: Callback endpoint redirects
- **WHEN** the canonical endpoint responds with a redirect to another origin or port
- **THEN** the helper refuses the redirect and does not forward the bearer

#### Scenario: Response exceeds its contract
- **WHEN** a callback response exceeds the action size bound or fails content-type/schema validation
- **THEN** the helper fails closed, keeps the token redacted, and does not distribute partial data

### Requirement: Callback actions are reviewed security contracts
Each registered action SHALL declare a versioned request/response schema, security tier, read-only or mutating effect, data sensitivity, bearer versus proof-of-possession eligibility, mandatory target binding, TTL/budget/size limits, service-principal eligibility, approval requirements, idempotency/retry semantics, audit fields, and deployment maximum. Catalog metadata SHALL bind a reviewed immutable SCM revision and content hash to its declared actions. Changing revision, action declarations, response schema, template binding, or security tier SHALL require review and reapproval.

This change authorizes only the read-only public-CA bundle action with a short-lived bearer. A secret-returning, mutating, signing, credential-minting, or reusable action SHALL require a separate OpenSpec security review and SHOULD use workload OIDC, mTLS, or proof of possession rather than a bearer alone.

#### Scenario: Playbook requests an undeclared action
- **WHEN** a playbook attempts an action not declared by its reviewed revision and bound template
- **THEN** ServiceRadar denies the action even if the actor could perform it interactively

#### Scenario: AWX runs a different revision
- **WHEN** the accepted AWX job cannot prove it ran the approved SCM revision/content hash
- **THEN** the callback remains unavailable and the child execution fails supply-chain verification

#### Scenario: Future action is more sensitive
- **WHEN** a proposed callback would return a secret, mutate state, sign data, or mint credentials
- **THEN** it cannot be added under the generic read-only contract and requires a separate approved security design

### Requirement: Service principals have fixed non-expanding ceilings
Unattended external automation SHALL use an explicit owned service principal with fixed tenant, action, catalog/template/revision, target ceiling, TTL, request budget, owner, expiry, rotation, and disable policy. Wildcard actions, wildcard tenants, unrestricted target selection, and self-expansion SHALL be prohibited. Workload OIDC or mTLS identity SHOULD be preferred to a long-lived bearer credential.

#### Scenario: Scheduled service automation
- **WHEN** a schedule initiates a callback-enabled playbook without an interactive human
- **THEN** its explicit service principal and fixed target/action ceiling form both the issuance-time and current-authority boundary

#### Scenario: Service owner disables the principal
- **WHEN** the service principal expires, is disabled, loses its owner, or violates rotation policy
- **THEN** outstanding grants are revoked and new grants cannot be minted

### Requirement: Callback lifecycle has durable secret-free audit
ServiceRadar SHALL durably audit grant mint, pending-to-active transition, envelope resolution, dispatch accepted/ambiguous, callback allowed/denied/replayed, budget consumption, response fingerprint and policy version, revocation, expiry, terminal cleanup, and detected misuse. Audit records SHALL use the grant ID and MUST NOT contain the token, token hash, envelope plaintext, public response body, or secrets. A successful use SHALL fail closed if its use/budget/audit commit cannot be durably recorded, and misuse/abnormal replay SHALL generate an operator-visible security signal.

#### Scenario: Successful use cannot be audited
- **WHEN** ServiceRadar cannot atomically commit grant consumption, response fingerprint, and success audit
- **THEN** it does not return the callback response and the grant remains unavailable for unsafe reuse

#### Scenario: Revoked token is replayed
- **WHEN** a revoked or expired bearer is presented again
- **THEN** ServiceRadar denies it, records only the non-secret grant ID and reason, rate limits repeated attempts, and raises the configured security signal
