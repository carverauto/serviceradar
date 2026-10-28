# Persistent recording installation

## Approved architecture direction

The user selected per-replica persistent storage through an opt-in StatefulSet.
Retain the configured core replica count and give each replica its own persistent
spool. Capture already runs on the relay owner;
this placement reuses the existing pipeline without opening a second RTSP
connection or introducing a distributed media transfer service.

A single-core installation with one PVC is simpler, but changes availability and
capacity for all core responsibilities. It is a separate demo-only alternative,
not a silent prerequisite for recording. A dedicated recorder service would
require a new ingest/ownership boundary and is outside this installation slice.

The selected option has a migration cost: changing Kubernetes controller
kind is not an ordinary rolling upgrade. Plan a maintenance window for the
initial conversion. Subsequent pod replacement retains that ordinal's claim;
this does not replicate application journals or implement recorder takeover.

## 1. Chart and volume contract

The default rendering remains the existing Deployment, with no recording claim,
initializer or recording admission. The explicit persistent-spool mode renders
a core StatefulSet, preserves existing service/discovery, mTLS, network policy,
resource limits and shutdown behavior, and uses one claim per ordinal.

Use volumeClaimTemplates and explicit PVC retention of Retain on deletion and
scale-down. Each backing PV must also have Retain reclaim policy: retaining a
claim during scaling does not protect a volume after a later claim deletion.
Provisioning preflight verifies the actual bound PVC/PV and CSI configuration;
a StorageClass name alone proves neither retention nor encryption.

Require a qualified CSI driver with ReadWriteOncePod for this initial mode.
ReadWriteOnce constrains the node and can still permit two pods on that node;
it is not sufficient evidence of exclusive initializer/recorder access.
An unsupported driver is an explicit installation refusal. There is no
automatic fallback to a shared RWX root, hostPath or emptyDir. Reuse the chart's
existing encrypted-storage policy and explicit lab exception; hosted readiness
still requires the configured encryption policy to be verified.

Retain claims outside ordinary release cleanup. Uninstall, scale-down or
switching recording off cannot authorize deleting footage. The Cloud
preservation inventory must outlive the workload and Helm release.

Kubernetes documents [stable StatefulSet storage and PVC retention](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#persistentvolumeclaim-retention)
and the separate [access-mode and PV reclaim contracts](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes).
Driver support and the actual installed version remain acceptance checks.

## 2. Explicit identity and initialization

Infrastructure allocates a UUID for each storage lifetime and retains the
association between that UUID, PVC UID, PV UID and CSI volume handle in private
operational inventory. Cloud owns the hosted inventory. The pod ordinal is only
a lookup key for that association; neither a pod name nor a node name generates
a storage UUID.

A bounded, versioned installation document selects the expected UUID for the
current StatefulSet member. Runtime configuration must reject missing,
duplicate, malformed or ambiguous mappings before allowing capture. Preserve
the existing explicit scalar UUID configuration for installations outside this
mode; configuring both sources is an error. Startup reads expected identity
from installation configuration, never adopts the marker as its authority.
The local marker continues to detect misbinding rather than attest a physical
volume by itself.

Initialize each intended claim explicitly while no core pod mounts it. The
provisioning operation verifies the expected claim/PV identity, creates only a
designated private spool subdirectory on the mounted volume, then calls the
existing Storage.initialize/2. Keeping a subdirectory avoids treating filesystem
housekeeping entries at the mount root as recording data. Existing directory
permissions, nonempty unmarked roots and conflicting/partial markers are
preserved and refused, not repaired. Exact retries follow the existing marker
contract.

Use an explicit release-callable provisioning mode packaged through Bazel and
a separately invoked one-shot Kubernetes Job. It must not start the ordinary
core application, join the Erlang cluster, run migrations, or acquire recording
authority. It is not an automatically rerun Helm hook or startup init container.
Give it only the intended volume and installation identity, with no camera,
database or object-store credentials. Restrict filesystem permissions to the
existing core runtime UID/GID without recursive chmod/chown over retained bytes.

Verify the marker and recorded volume association, observe the Job exit and
unmount, then start the matching StatefulSet member with recording disabled.
Normal startup and capture only verify; replacement with an empty volume must
fail instead of formatting or assigning a new identity.

For scale-up, provision and initialize the new ordinal claims before increasing
the workload replicas. Existing ordinal mappings remain immutable while their
volumes are retained. Expansion, replacement and reattachment require explicit
inventory reconciliation; an ordinal is not permission to reuse a different
volume under the old UUID.

## 3. Conversion, rollback and failure

The initial conversion is an explicit operator procedure:

1. Verify supported CSI/access mode, retention/encryption, proposed volume
   associations, storage budget, compatible product/chart versions and Cloud
   restore support. Keep recording admission disabled.
2. Provision and initialize the new claims under exclusive ownership. Retain
   evidence of both successful and unresolved attempts.
3. Enter the approved maintenance window, stop new core work and drain/retire
   the Deployment using its existing shutdown and lease semantics. If recording
   had already been enabled manually, preserve every spool and wait for exact
   owner retirement before proceeding. A stop request is not fleet-drain proof.
4. Verify the old controller has no running owners, then install the
   StatefulSet with the same service interfaces. Do not run both controller
   kinds against overlapping core selectors as a migration strategy.
5. Verify all requested members, actual claim associations, marker checks,
   clustering, telemetry, jobs and shared camera ingest. Only later acceptance
   may install recording admission.

Cloud and local rollout tools must select and verify the installed controller
kind explicitly. They must refuse ambiguous or mixed controller observations.
An automatic Helm rollback must not resurrect the old Deployment alongside
the StatefulSet. The migration implementation must define this guard and its
failure recovery before it can be used.

Rollback stops new recording/work, observes owner retirement and preserves
claims and their inventory. Returning to a Deployment restores service only;
it does not move provisional recordings or make inaccessible bytes available.
Do not force-delete a stuck pod or attach its claim elsewhere to accelerate
recovery. Resolve the old owner's status before any replacement writer.

A retained volume can still be inaccessible or lost. Report local-only coverage
as unavailable; use only a verified archive for fallback. This installation
does not add automatic block adoption, restart reconciliation, replication,
continuous recording, upload scheduling or deletion authority.

## 4. Cloud work before hosted activation

Scope these enhancements in the existing
[storage provisioning issue #182](https://github.com/carverauto/serviceradar-control/issues/182)
and [lifecycle issue #183](https://github.com/carverauto/serviceradar-control/issues/183):

- Inventory each spool lifetime, provider/CSI identity, capacity, encryption,
  initialization state, member association and sticky preservation status.
  Retain unresolved allocations and claims after scale-down or workload removal.
- Materialize the versioned identity document and chart mode only after the
  matching volume checks. Preserve installation revisions and verify each
  member's observed application; one pod's acknowledgment is not fleet readiness.
- Gate provisioning, scale-up, suspend/resume and termination on observed owner
  retirement and retention obligations. Generic cleanup cannot purge spools.
- Update restore planning and execution to use the installed core controller
  kind, tracked in [Cloud #190](https://github.com/carverauto/serviceradar-control/issues/190).
  At inspected Cloud main 349e37bb, both
  tenant_restore_execution_plan.ex and tenant_restore_execution/helm_driver.ex
  use the Deployment path. Both must change together, with positive coverage
  for each supported kind and refusal of unknown/mismatched kinds.
- Restore CNPG/media inventory consistently with retained volume identities.
  Database recovery alone cannot establish possession of provisional media.
- Keep all monitored-camera secrets in the runtime credential inventory.
  The installation identity document contains no secret material.

Cloud recording readiness remains blocked until the existing provider
qualification, per-purpose authorities and preservation requirements pass.
This proposal changes none of the allocation-ownership gate or nineteen
qualification checks.

## 5. Implementation and evidence boundaries

Separate reviewable passes cover runtime identity/provisioning, Helm packaging,
Cloud inventory/restore and deployment acceptance. Each pass preserves all
existing ownership, spool, capture, publication and browser assertions.

Execute the chart renderer and validate normalized manifests for default and
opt-in modes, per-member claims, retention, disabled recording and invalid
configuration. Runtime tests exercise the real identity resolver and filesystem
initializer with independently invented inputs; they must prove wrong identity,
replacement, aliasing and incomplete initialization cannot gain authority.
Retain the existing real-worker database tests rather than replacing them with
source-text assertions.

Synthetic Kubernetes acceptance must demonstrate claim reuse after pod
replacement, denial of a concurrent mounting writer, initialization retry,
scale-down/uninstall preservation, conversion refusal while old owners remain
and a safe interrupted-conversion recovery. Only then run a bounded trial in
the operator-designated deployment. Keep actual resource IDs, media and
diagnostic artifacts in private operational state.

A successful one-shot capture must yield a frozen local block receipt while
another viewer continues. Archive qualification/upload/publication and
authorized browser replay remain separate acceptance steps. Do not report a
retained PVC or local freeze as an available recording.

Live runtime validation remains mandatory after implementation: exclusive mount,
identity mismatch refusal, pod replacement, retention, bounded capture and viewer
continuity must be exercised. This docs-only change cannot execute those future
behaviors. The user accepted proceeding without live validation for this planning
checkpoint only; implementation and all other acceptance gates remain required.
