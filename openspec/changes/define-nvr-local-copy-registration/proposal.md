# Change: Qualify local NVR storage before registering recording copies

## Why

The standalone NVR can now retain, authenticate, deliver and retry publication
intents. Core's `intent_accepted` response confirms correlation with a frozen
recording block. It deliberately does not establish storage durability or create
a qualified local-copy catalog entry.

The next implementation needs an explicit source of storage-qualification
authority. Treating that acknowledgement, a PVC name or an NVR-supplied `healthy`
flag as qualification would violate the approved worker-node-loss guarantee.

## What Changes

- Define deployment-owned qualification of an exact storage lifetime and provider
  configuration, separate from the recorder's content verification.
- Define distinct local-copy registration and acknowledgement records, preserving
  the existing v1 intent/acknowledgement and S3 archive contracts.
- Separate historical registration, current storage eligibility, route
  reachability and fresh playback authorization.
- Specify revocation, exact retries and consistent-history restore, including the
  refusal paths needed before local publication can be enabled.

This proposal adds no resource, migration, endpoint, deployment or qualification
claim. Review of this contract precedes implementation. Existing automatic intent
delivery remains unchanged and disabled by default.

## Scope and dependencies

This refines tasks 3.1 and 3.3 of
[the recorder-plane plan](../add-scalable-camera-recording-plane/tasks.md) and
implements the boundaries already required by its
[local publication contract](../add-scalable-camera-recording-plane/local-publication.md).
It does not replace that contract's preservation, deletion or restore rules.

Offline grants, customer-originated transport, playback admission, numerical
capacity SLOs and physical storage qualification remain separate work. Longhorn
and Ceph RBD remain candidate providers; neither becomes qualified by name.
