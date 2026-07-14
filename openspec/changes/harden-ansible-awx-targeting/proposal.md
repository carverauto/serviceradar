# Change: Harden Ansible AWX targeting and launch custody

## Why

ServiceRadar can currently dispatch AWX verbs and persist run/event data, but its launch path is not safe enough for configuration or remote-access enrollment. A device carries one mutable AWX reference, hostnames can substitute for inventory identity, `inventory_id` is dropped at dispatch, an empty limit can broaden execution to a template's inventory, target-row failures are ignored, job/event lookup is not controller scoped, and secret-capable `extra_vars` plus `SystemActor` obscure the human authority behind a run.

The callback-grant and SSH-CA enrollment children require a canonical launch boundary that cannot expand targets, authority, credentials, or content while work crosses the asynchronous ServiceRadar -> edge agent -> AWX path.

## What Changes

- Introduce durable AWX host memberships keyed by `(controller_id, inventory_id, awx_host_id)` and linked explicitly to canonical device UID; preserve duplicate hostnames and multiple memberships without last-writer-wins execution identity.
- Build immutable parent-operation and child-launch snapshots partitioned by controller, inventory, job template, project/revision, execution environment, approved machine credential reference, reviewed static custom credential or dynamic custom-credential type/slot, check mode, and exact target memberships.
- Re-fetch AWX host/template state before dispatch, reject drift, require an explicit compatible inventory and safe literal-only non-empty limit, create every target row transactionally, verify the full accepted AWX job configuration, and reconcile job-scoped host IDs against the exact snapshot.
- Preserve and reauthorize the initiating human or fixed-ceiling service principal. System workers may transport an approved snapshot but cannot become the authorizing actor or enlarge it.
- Require `ansible.delegations.manage` for selecting a separate service principal and attenuate every schedule delegation against issuer scope, execution-principal ceiling, approval, and deployment maximum.
- Replace persisted raw/secret-capable variables with reviewed typed non-secret public/internal values and prebound AWX credential references; prohibit ServiceRadar-collected launch secrets, secret-value digests, callback bearers, and sensitive surveys/`extra_vars`.
- Bind every on-demand mutating AWX bearer grant to a versioned request-body policy: exact control-plane-produced launch bytes, an explicitly empty body, or the one reviewed callback host rewriter. Keep trusted bytes outside Wasm, reject secret-bearing launch values before opaque encoding, permit at most one mutation, and enforce the body before credential resolution or network transport.
- Keep scheduled inventory-sync bearer material outside Wasm memory: deliver it only in dedicated protobuf `host_params_json` field 23, expose only a fixed sentinel through `get_config`, make new-control-plane/old-agent rollout fail closed, and inject it solely for empty-body `GET` requests under the exact controller's `/api/v2/inventories/` subtree and configured TLS policy.
- Scope AWX jobs by controller and child execution, correlate host events by AWX host ID inside the immutable child snapshot, and treat hostname/address as display/correlation evidence only.
- Project every AWX result into a secret-free schema under one 3 MiB aggregate budget; version event windows and retain a bounded one-release v0.1.5 compatibility projection so rolling upgrades cannot persist raw controller/module output or stall idle jobs.
- Add exact timeout reconciliation through a reserved non-secret AWX-visible dispatch marker and compensate any partial multi-child dispatch by stopping undispatched children, canceling accepted jobs, and revoking prepared callback state.
- Add dispatch ambiguity, cancellation, stale-membership, and an authenticated versioned mutation-phase state machine; critical/unknown/uncommitted mutation states hold the canonical device across all AWX memberships until authorized reconciliation.
- Detect authority contraction through change invalidation plus bounded pulse-time reauthorization, revoke callbacks, cancel active children, and hold mutation targets when cancellation cannot be proven.
- Add exact `ansible.targets.holds.clear` RBAC, administrator-only by default and approval-gated, for evidence-backed hold reconciliation; ordinary launch/cancel permission cannot clear a hold.
- Expose a launch-gate seam for reviewed callback action declarations without implementing callback grants in this child.

**BREAKING**: Launches with a mutable/ambiguous AWX membership, empty or inexact limit, incompatible template inventory, undeclared inputs, plaintext secret, unbound content/credential, missing actor authority, target-row error, ambiguous dispatch, or unresolved target hold are rejected instead of falling back to hostname, template defaults, worker authority, or persisted variables.

## Impact

- Affected specs: `ansible-awx-targeting` (new)
- Affected code: Ansible Ash resources/migrations, credential-broker request-body policy and grant schema, `RunLauncher`, schedules, AWX catalog and inventory reconciliation, `AwxClient`, agent command/body custody, edge HTTP host enforcement, command context/envelopes, event ingestor/pulse/watchdog/cancel flows, run/device UI, RBAC catalog, and tests
- Supersession: this child replaces the unsafe or unimplemented run-authorization, device-linkage-for-execution, target persistence, schedule launch, and event-correlation portions of the active `add-ansible-integration` proposal; it does not redefine the already delivered AWX controller/inventory-sync or verb-bridge baselines
- Prerequisites: merge the truthful inventory-sync and verb-bridge archive changes before implementation so current specs represent the delivered baseline
- Unblocks after approval/implementation: `add-automation-callback-grants`, integrated portions of `publish-ssh-ca-ansible-enrollment`, and any live fleet enrollment
- Explicitly out of scope: callback token issuance/API, SSH CA data/signing, public Ansible role implementation, AWX/live host mutation, Proxmox console, SSH/RDP transport, and demo rollout
