# Retained spool installation inventory

This is the infrastructure contract for the chart/provisioning implementation.
It does not add a runtime reader, create resources, qualify storage or authorize
conversion. The runtime continues to consume only the existing
[version-1 member projection](identity-configuration.md).

## Ownership and bounds

Cloud owns hosted installation and volume records. A standalone installation
keeps equivalent private, durable operational records outside the runtime Helm
release. Neither runtime CNPG restore nor Helm history is the authority for
replacing those records. No SaaS account routing enters the product runtime.

Use one installation record and one record per allocated storage lifetime.
Do not put an ever-growing collection of retired volumes into the runtime
identity document. Installation snapshots are limited to 65,536 UTF-8 bytes and
256 selected members; each volume record is limited to 16,384 bytes. Retained
volume records remain individually addressable after their member is removed
from the installation projection. Hitting a bound refuses new admission; it
never evicts preservation records to make room.

Both record types have integer `version: 1`. Reject duplicate JSON keys,
unknown fields, unsupported versions, malformed names/identities and truncated
or oversized input before any resource mutation. UUIDs use the canonical
lowercase form required by the runtime resolver. Kubernetes UIDs are opaque,
nonempty strings of at most 128 bytes; they are compared exactly, not generated
from names. Revisions are positive integers no larger than 2^63 - 1.

This describes the logical interchange contract. Cloud can store it using its
existing durable provisioning and preservation resources; it does not require
a second workflow engine or JSON files in the database.

## Installation record

| Field | Contract |
| --- | --- |
| `version` | Integer 1. |
| `installation_id` | Infrastructure-allocated UUID, retained across workload replacement. |
| `revision` | Compare-and-set revision of this installation snapshot. |
| `namespace` | Object with the Kubernetes namespace `name` and observed `uid`. |
| `controller` | Object with `name`, desired `kind` (`Deployment` or `StatefulSet`) and observed `uid`; UID is null until the selected controller exists. |
| `phase` | `deployment`, `draining`, `statefulset` or `unresolved`; transitions follow [the conversion protocol](conversion-protocol.md). |
| `members` | Map from exact StatefulSet member names to storage UUIDs. Empty is allowed before selection; active StatefulSet mode requires one entry per requested ordinal. |
| `fence` | Object with independent admission `policy_name`, `binding_name` and `parameter_name`, plus their observed UIDs and applied `revision`; null before installation. |

Names use the Kubernetes syntax for their corresponding resource. Member names
also obey the runtime resolver's exact 253-byte key contract. The namespace UID
must match the API observation: recreating a namespace with the same name is a
different installation target. Resource names alone never establish ownership.

The projection is exactly `{"version":1,"members":{...}}`, with no additional
runtime fields. Validate it using the existing resolver and its byte/member
bounds before installation. Its installed revision and checksum are recorded
separately; a projected ConfigMap update requires a controlled core restart.
Do not infer fleet application from one member or from ConfigMap creation.

In `statefulset` phase, the member set covers every requested ordinal, including
members temporarily unavailable. Scaling down removes the member from active
selection only after retirement; it leaves the volume record intact. Scaling
back up selects the same lifetime after revalidation. An explicit replacement
allocates a new UUID and preserves the previous record; it never overwrites the
previous association or silently assigns a fresh UUID to existing bytes.

## Volume record

| Field | Contract |
| --- | --- |
| `version` | Integer 1. |
| `storage_id` | Independently allocated UUID; immutable identity of this volume lifetime. |
| `installation_id` | Owning installation UUID. |
| `revision` | Compare-and-set revision of this volume record. |
| `member` | Exact intended StatefulSet member key; retained even when scaled down. |
| `state` | `reserved`, `bound`, `initialized` or `unresolved`. |
| `claim` | Object with intended PVC `name` and observed `uid`; UID can be null before binding while reserved or unresolved. |
| `volume` | Null before binding, otherwise an object with PV `name`, PV `uid`, CSI `driver` and CSI `handle`. Driver is a Kubernetes CSI driver name; handle is an opaque, nonempty string of at most 1,024 bytes. |
| `capacity_bytes` | Requested minimum capacity as a positive integer no larger than 2^63 - 1; the bound claim and volume must meet it, with actual capacity retained in qualification evidence. |
| `qualification_ref` | Null until a private immutable qualification record exists; otherwise an opaque reference of at most 256 bytes. |
| `initialization_ref` | Null until the initializer result is reconciled; otherwise an opaque private evidence reference of at most 256 bytes. |
| `preservation_required` | Always true for this protocol. Clearing it or deleting retained resources requires the separate preservation-aware lifecycle authority. |

Reserve the UUID and intended claim/member before requesting a claim. If the
create response is lost, reconcile the intended operation and actual object
ownership. Finding a same-named claim does not authorize adopting it.

An unresolved allocation can contain an incomplete observation. Preserve every
identity already observed and leave unknown components null; do not erase a
previously complete association. `bound` and `initialized` require a complete
claim and volume identity. `initialized` also requires both evidence references.

Record the PVC UID, PV UID and CSI driver/handle as one immutable bound
association. Verify the PVC's `spec.volumeName`, the PV's `claimRef` name,
namespace and UID, both resources' bound state, and the CSI identity together.
No two retained lifetimes may claim the same physical driver/handle, PVC UID or
PV UID. After binding, any changed component makes the record unresolved;
repair is an explicit reconciliation operation, not an in-place overwrite.

Before initialization or any new member admission, re-observe that association
and the actual storage properties:

- Filesystem mode and `ReadWriteOncePod` on the claim and volume, supported by
  the installed CSI driver and sidecars, plus a real concurrent-mount denial.
- `Retain` on the actual bound PV, and retained claim/controller policy. A
  class default does not override the policy of an already allocated PV.
- The required encryption configuration and provider-side evidence for this
  volume. A class name or claim annotation does not prove encryption. An
  explicit local/lab exception remains visible as an exception and cannot
  satisfy hosted encryption readiness.
- Capacity, installation/member identity and exclusive ownership. Refuse
  unknown, substituted, inaccessible or still-mounted volumes.

Qualification records identify the observed resource UIDs, inventory revision,
driver/capability evidence and encryption policy. Revalidate on reattachment,
replacement, restore or policy changes; a historical successful check is not a
perpetual readiness grant. Do not copy provider credentials into this record.

`initialized` requires the matching exclusive Job UID, successful bounded
filesystem result, exact marker verification, observed process exit and unmount.
A successful Job status alone is insufficient. Record ambiguous execution as
`unresolved` and preserve the claim. Never delete or repair a partial marker to
make a retry pass. The [initializer contract](../../../docs/camera-spool-initialization.md)
continues to own filesystem semantics.

## Retention and restore

The inventory and admission fence survive workload removal and runtime Helm
uninstall. Restore reads the retained external inventory, compares the observed
controller/namespace/volume identities, and refuses stale or conflicting plans.
Restoring CNPG metadata cannot reset a volume to `reserved`, clear preservation,
reassign an old UUID, or prove possession of inaccessible provisional media.

Cloud implementation belongs to [#182](https://github.com/carverauto/serviceradar-control/issues/182)
for inventory, qualification and materialization, and
[#183](https://github.com/carverauto/serviceradar-control/issues/183) for retained
lifecycle and deletion authority. Controller-aware restore remains
[#190](https://github.com/carverauto/serviceradar-control/issues/190).
