# Camera spool volume-association preflight

`//go/cmd/tools/camera-spool-preflight` is an operator-invoked, read-only
Kubernetes API check. Supply expected identities from the retained installation
inventory. It detects a same-named replacement claim or volume before a later
provisioning operation. It neither discovers an identity to adopt nor updates
inventory, resources or filesystem markers.

## Invocation

Provide an explicit trusted kubeconfig file and context; the current context
and in-cluster credentials are not implicit defaults. As with kubectl, a trusted
kubeconfig may invoke a credential plugin. Keep credentials outside the build
inputs and source tree.

This example is entirely invented. Replace its values with the installation's
retained expectations, not values rediscovered and automatically accepted from
a possibly substituted volume:

```sh
bazel run -c opt --config=remote \
  --platforms=//build/platforms:darwin_aarch64 \
  //go/cmd/tools/camera-spool-preflight -- \
  --kubeconfig /private/operator/kubeconfig --context example-installation \
  --namespace example-recording --namespace-uid namespace-lifetime-example \
  --claim recordings-camera-0 --claim-uid claim-lifetime-example \
  --volume volume-example --volume-uid volume-lifetime-example \
  --csi-driver storage.example.com --csi-handle volume-handle-example \
  --minimum-bytes 1073741824
```

The platform flag cross-compiles for an Apple Silicon operator machine while
compilation runs remotely. Omit it for the repository's default Linux target.
Every worktree must have its ignored remote Bazel configuration before invoking
Bazel. `bazel run` executes the resulting command on the operator machine; only
compilation belongs on the remote executor.

All eleven flags are required. Names use Kubernetes DNS validation, expected
UIDs are nonempty and at most 128 bytes, and the CSI handle is nonempty and at
most 1024 bytes. The reserved minimum is a positive signed 64-bit byte count.
Unknown flags, extra arguments and invalid input refuse before API reads.

## Observed conditions

The command requires these observations:

- The namespace is active, has the retained UID and is not being deleted.
- The named PVC and PV have their expected UIDs, are bound and not deleting,
  and link to each other by volume name and claim name, namespace and UID.
- Both declare filesystem storage and exactly ReadWriteOncePod. The PVC's
  request, reported capacity and the PV's capacity meet the reserved minimum.
- The actual PV has `Retain` reclaim policy. Neither object has cleanup owner
  references, and their storage classes match.
- The PV's writable CSI source matches the retained driver and volume handle;
  that driver object exists and is not deleting.
- No pod in the namespace references the claim, including completed or deleting
  pods and generic ephemeral claim references. No VolumeAttachment names the
  PV, including pending or reported-detached attachments.

Required RBAC is `get` for the selected namespace, PVC, PV and CSIDriver, plus
`list` for namespace pods and cluster-wide VolumeAttachments. Read denial is a
refusal, not evidence that no consumer exists. No create, patch, update or delete
permission is used. Resource lists request 100 objects per page and stop after
100 pages per kind; exhaustion refuses. API observation has a 30-second deadline.
The operator still needs an outer process deadline for external credential
plugins and the surrounding provisioning procedure.

Kubernetes documents the distinct [access-mode and reclamation contracts](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes)
and the [VolumeAttachment API](https://kubernetes.io/docs/reference/kubernetes-api/storage/volume-attachment-v1/).
A CSI driver object alone does not attest capability, installed sidecar versions,
encryption, physical exclusivity or the state of a node's mounts.

## Result and authority boundary

An association check emits one JSON object:

- Exit `0`, `{"status":"association_verified"}`: the API observations matched.
- Exit `1`, `{"status":"refused","reason":"..."}`: input or observation failed.
  Reasons are bounded categories without resource identities or raw API errors.
  A killed process or unreadable output has no successful result.

`--help` (or `-h`) instead prints plain-text usage and exits `0` without API
reads. Automation must require both exit `0` and the JSON status
`association_verified`; a zero exit status alone is not an association result.
An output write failure exits `1` and may leave incomplete output.

Examples include `claim_identity_mismatch`, `volume_not_retained`,
`csi_identity_or_access_mismatch`, `claim_referenced_by_pod`,
`volume_attachment_present`, `pods_read_denied` and `resource_scan_limit`.
Preserve unresolved storage and reconcile explicitly; do not format, delete,
rewrite a marker or adopt a replacement in response to refusal.

Success is a snapshot of sequential API reads, not a lock or a physical-volume
attestation. A later pod or attachment can invalidate it. It does not discover
other aliases for the same CSI handle, prove unmount or exclude out-of-band
storage access. Retained inventory uniqueness, independently installed admission
fencing, qualified RWOP behavior, encryption policy and observed owner retirement
remain mandatory before the exclusive initializer can run. The initializer's
exit and unmount must then be observed before admitting a core member.

This command does not authorize initialization, controller conversion, recording,
archive upload or playback. See the [installation inventory](../openspec/changes/add-persistent-camera-spool/installation-inventory.md),
[conversion protocol](../openspec/changes/add-persistent-camera-spool/conversion-protocol.md)
and [filesystem initializer](camera-spool-initialization.md). Job packaging and
runtime admission remain separate work.

## Validation ownership

`//go/cmd/tools/camera-spool-preflight:camera-spool-preflight_test` drives the
command with an explicit kubeconfig and the real Kubernetes client against
invented HTTP API responses. It asserts exit status and JSON for retained
association, substituted identities, unsafe storage, pod/attachment references,
later pages, incomplete scans and denied reads. The server rejects every
mutation. Invalid input must produce no API requests.

Live command validation uses only separately created empty test resources, with
observed refusal before and success after changing the test PV to Retain,
identity/capacity refusals, and refusal while a scheduling-gated test pod refers
to the claim. Remove only those test-owned resources and verify cleanup. Such a
test checks the API boundary; it does not qualify the driver, actual mounting,
encryption, deployed capture or playback.
