# Guarded core controller conversion

This specifies task 1.3; the guard and conversion tool are not implemented yet.
The approved per-replica architecture does not authorize an installation or a
maintenance window. Chart support must not be activated until the guard,
storage preflight and synthetic acceptance below are implemented.

## Why a chart check is insufficient

The core Deployment and proposed StatefulSet use the same service/discovery
interfaces. Switching `kind` is a controller replacement, not a rolling update.
The preparatory chart fix preserves an explicit `core.replicas: 0` instead of
replacing it with one replica. This requests a drain; observed owner retirement
is still required before using it for conversion.

A Helm `lookup` guard in a new template cannot constrain an older revision's
templates, and offline GitOps rendering cannot establish live absence. An old
revision or automatic rollback could recreate the Deployment after a StatefulSet
was installed. A kept ConfigMap is evidence, not an enforcement mechanism.

## Fence independent of runtime Helm history

Use a narrowly scoped Kubernetes ValidatingAdmissionPolicy and binding, owned by
the infrastructure provisioner outside the runtime Helm release, with a durable
parameter record for the installation's allowed controller and revision.
Require the stable API, fail-closed evaluation, Deny enforcement and denial when
the parameter is missing or invalid. Unsupported admission capability is an
installation refusal; there is no lookup-only fallback.

Scope the fence to the exact installation namespace and core workload identity.
It must cover core controller creation/update, scale subresources and creation
of core pods, including attempts by retained ReplicaSets. Its contract is:

| Installed fence phase | Allowed behavior |
| --- | --- |
| `deployment` | Only the selected Deployment identity can admit core pods or positive replicas. |
| `draining` | No new core pod or positive replica admission from either controller kind. Scaling to zero, observing, and removing retired controllers remain possible. A replacement controller can be prepared at zero replicas. |
| `statefulset` | Only the selected StatefulSet identity can admit core pods or positive replicas; old Deployment revisions and ReplicaSets remain denied. |
| Missing, invalid or unresolved state | No new core owner admission. Observation and safe retirement remain possible. |

Resolve controller ownership to the observed UID, not only kind/name. For a
Deployment, its ReplicaSets and pods must belong to the selected owner chain;
for a StatefulSet, bind admission to the observed StatefulSet UID. A controller
recreated under the same name is not automatically trusted. Install/update the
owner association while draining before admitting its pods.

The guard protects against stale controllers and ordinary rollout/rollback
automation. Cluster administrators remain trusted; this is not protection
against an administrator deliberately deleting admission enforcement. Restrict
fence mutation to the infrastructure owner. Runtime service accounts and normal
release cleanup must not mutate or remove it. Its parameter and binding have no
runtime Helm owner reference or cleanup hook.

Do not merely inspect policy YAML. Check the applied revision and type-checking
result, then exercise both a permitted request and a refused competing-owner
request against server-side admission. A deny-only probe could pass because of
unrelated RBAC or malformed input. Observe those controls after every transition
and before increasing replicas. If enforcement is uncertain, keep admission
closed and record the installation as unresolved.

Kubernetes documents the [stable admission-policy mechanism and failure handling](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/).
The precise policy expressions, ownership projection and RBAC remain implementation
work and must pass real API-server acceptance, including scale subresources.

## Transition protocol

One infrastructure owner performs a transition using the expected installation
revision. Concurrent or stale operations refuse before mutation. Persist the
intended phase/operation before issuing a mutation, reconcile lost responses
against observed object UIDs and applied revisions, and never advance solely
because an API call returned success. This uses the existing Cloud provisioning
operation model; it does not introduce a general-purpose controller.

### Deployment to StatefulSet

1. Inventory the namespace, current controller UID, requested replicas and
   release/chart revision. Refuse unknown or simultaneous controller kinds.
   Verify compatible product, chart, Cloud restore and guard capabilities.
   Recording remains disabled.
2. Reserve and qualify the new per-member volumes under the
   [inventory contract](installation-inventory.md). Explicitly initialize each
   intended claim while no core pod mounts it. Retain all successful and
   unresolved attempts; observe the Jobs exit and unmount.
3. Install the independent fence in `deployment` mode bound to the actual
   owner, and prove permitted/denied admission. This installation itself
   requires operator authorization: it changes cluster admission policy.
4. Enter the approved maintenance window. Persist the draining intent, switch
   the applied fence to `draining`, prove that neither controller can create a
   new core owner, and stop new application work through existing shutdown and
   lease semantics. Scale the Deployment and its intended rollout to zero.
5. Observe exact old-owner retirement: controller generation acknowledged,
   zero desired/live replicas, no nonterminal or terminating owner-chain pods,
   and no unresolved application recording owner. A node partition, stuck
   termination, lost Job result or uncertain volume attachment stops conversion.
   Do not force-delete a pod or detach storage as a substitute for proof.
6. Remove the retired Deployment with observed completion. Render/install the
   StatefulSet at zero replicas, with `Retain` claim policies, the qualified
   per-member claims and matching identity projection. Preserve service,
   security, resources and shutdown contracts. No ordinary startup initializer
   or Helm hook may format storage.
7. Reconcile the new controller UID, actual claim associations and installation
   revision. Bind the fence to that UID, transition to `statefulset`, and prove
   the old Deployment/ReplicaSet path remains denied while the intended path
   is accepted. Only then admit the requested replicas with recording disabled.
8. Verify every member's mapping, mounted marker, clustering, telemetry/jobs
   and existing shared camera ingest. Persist observed application separately
   from desired configuration. Bounded capture and archive readiness retain
   their own acceptance requirements.

Disable Helm automatic rollback for a controller-kind transition. Failure must
leave admission closed or restricted to the last verified owner and preserve
resources for reconciliation. Do not retry with `--force`, resurrect an older
controller to recover availability, or substitute a historical Helm revision
for the transition protocol.

### Interrupted transition

On restart, compare the persisted intent with the admission fence, both
controller kinds, their owner-chain pods, Job/attachment state and retained
inventory. If the last mutation completed but its reply was lost, record that
observed result before resuming. If observations conflict, retain `unresolved`
and refuse new owners; do not choose whichever controller happens to be Ready.

A fence in `statefulset` mode with zero replicas can resume only the matching
StatefulSet after volume revalidation. A draining fence with no controller can
prepare the chosen replacement at zero. Neither case permits deleting claims
or silently falling back to a Deployment.

### StatefulSet to Deployment

Rollback is a new guarded transition, not `helm rollback` to a pre-conversion
revision. Stop new admission, apply/prove `draining`, and observe retirement and
unmount of every StatefulSet member before removing the controller. Preserve
all claims, identity records, initialization evidence and unresolved footage.

Prepare the Deployment at zero replicas, record its new observed UID, bind the
fence to it, and prove the stale StatefulSet path denied before admitting core
replicas. Returning to Deployment restores service only; it neither migrates
provisional recordings nor makes inaccessible footage available. Leave
recording disabled. A failed rollback remains fenced for reconciliation.

## Required implementation acceptance

- Default Deployment behavior and explicit zero replicas remain supported.
- A stale Helm/GitOps revision cannot admit an old controller or its pods;
  namespace/workload scope leaves unrelated workloads unaffected.
- Both permitted and denied controls exercise a real API server, including
  scale subresources, stale ReplicaSets, missing parameters and recreated UIDs.
- A lost response at every phase resumes from observation or refuses; mixed
  owners, terminating pods and unresolved attachments cannot advance.
- Retained claims and inventory survive scaling, runtime uninstall, interrupted
  conversion and rollback. Removing the guard requires a separately authorized
  decommission procedure after owner retirement; it is never release cleanup.
- The existing runtime filesystem, recording-owner, capture and viewer tests
  remain in force. A policy or PVC test cannot substitute for them.

Cloud plan generation and execution must use the same installed kind, owner UID
and revision checks; this is part of [Cloud #190](https://github.com/carverauto/serviceradar-control/issues/190),
with inventory and preservation owned by #182/#183. Live conversion stays
blocked until those dependencies and the approved maintenance window exist.
