# Private archive binding registration

Cloud registers one immutable destination before requesting qualification or init
upload authority. Registration stores metadata only: it does not contact the
provider, resolve credentials, adopt a bucket, bind a recording block, enable
recording or qualify storage. Provider ownership and reservation remain Cloud
responsibilities.

## Request and authentication

`POST /v1/media/archive-bindings` uses the existing private control-plane
listener and deployment-bound media authentication. The account/password-reset
credential, storage-service credential and ordinary Kubernetes Authorization
header do not substitute for the media credential. Authentication precedes body
parsing; the server supplies the fixed `archive_binding_control` system actor.
No caller-selected actor or media installation identity is accepted in the envelope.

The JSON body is at most 4096 bytes and has exactly `schema_version: 1` and
`destination`. Duplicate keys, including escaped duplicate spellings and nested
duplicates, are rejected before the general JSON parser. The destination uses
exactly the existing eleven fields and bounds from `ArchiveDestination`:
`schema_version`, `provisioning_ref`, integer `generation`, `purpose`, `provider`,
`endpoint`, `region`, `bucket`, `namespace`, `archive_format_version` and
`required_encryption`. It currently supports recording through S3-compatible
storage with `recordings/v1`, format 1 and `sse_s3_aes256` only.

## Receipt and retry

Both first registration and an exact retry return HTTP 200 with exactly:

- `schema_version: 1`, `status: registered`;
- product-assigned `binding_id`, the original `provisioning_ref` and integer
  `generation`, and the product-computed `destination_sha256`;
- `capability_state: unqualified`, `readiness: unavailable` and
  `reason: archive_binding_only`.

The existing `ArchiveBinding.register` action owns idempotence. The same
provisioning reference and generation with different destination content returns
409 `archive_binding_conflict` and leaves the retained destination unchanged.
A distinct generation creates another immutable identity; it does not retarget
old blocks or revoke old bindings. A caller that loses the response retries the
same document and receives the same identity instead of inventing another
reference. Cloud persists the receipt beside the exact original provisioning
intent; it does not recompute the product's destination digest.

Invalid envelopes/destinations return 400, oversized bodies 413 and unsupported
media types 415. Storage failures return a bounded 503 without database or
credential details. All responses disable caching. Registration never creates a
qualification receipt or init authority. Full provider qualification, local spool
identity, private workload provisioning and preservation before teardown remain
separate prerequisites.
