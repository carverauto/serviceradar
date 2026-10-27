# Authorized archive fragment reads

This checkpoint serves one complete initialization object or one frozen media
fragment from an already published archive. Recording remains disabled by
default. This is not timeline discovery, HLS assembly, provisional local
playback, export, hosted provisioning or provider qualification.

## Public boundary

The authenticated routes are:

- `GET /api/cameras/:camera_source_id/recordings/:id/init`
- `GET /api/cameras/:camera_source_id/recordings/:id/fragments/:index`

The fragment index is a canonical zero-based decimal position in the frozen
descriptor. The service chooses its exact offset, length and digest. Clients
cannot supply object keys, provider URLs, versions or byte intervals. A `Range`
header is rejected; these routes identify bounded fragment resources rather
than expose a packed object. Initialization bytes are limited to 1 MiB and each
fragment to 4 MiB. Larger valid descriptor fragments are unsupported by this
checkpoint and fail before network I/O.

The [recording access policy](../../../docs/docs/rbac-and-roles.md#recording-metadata-and-footage)
owns required permissions, role defaults and authority refresh. Both routes read
the Source under the refreshed user's scope and repeat that check before delivery.
Successful responses contain only `video/mp4` bytes and use
`Cache-Control: private, no-store` and `X-Content-Type-Options: nosniff`.

Malformed identifiers, noncanonical indices and supplied ranges return 400;
unauthenticated and forbidden requests return 401/403. Missing or wrong-camera
blocks return 404. Unavailable archive proofs return 409. Unsupported or absent
fragment ranges return 416. Transport, configuration, integrity and deadline
failures return a bounded 503 without provider details or partial bytes.

## Proof and byte ownership

`ArchiveUploads.archive_range/4` reuses the canonical block, init, media and
manifest lock order. It requires current published availability and derives an
internal read plan from the frozen descriptor and retained verified object
identity. It never acquires upload ownership, changes a receipt or accesses
storage. No database transaction remains open during network I/O.

Web sends that plan to the installed isolated reader. The reader uses its fixed
binding/destination and read credentials for one identity-bound provider GET.
The existing egress range owner checks exact status, framing, interval, total
size, strong ETag and version. The selected bytes must match their frozen
SHA-256. Redirects, retries, whole-object fallbacks and local-spool fallbacks are
not permitted.

After the bytes arrive, Web reloads current human authority and the entire
canonical read plan. Delivery requires exact plan equality, the expected byte
count and digest, and an unexpired ten-second delivery deadline. The final
authorization check is the release point for this bounded response; it does
not promise to retract bytes already delivered to a socket. A late conflict or
permission revocation before that point withholds the response body.

Historical reads do not depend on recording admission or expired upload grants.
GET is repeatable and this checkpoint adds no durable read lease. Future
retention, holds and deletion workers must integrate with this contract before
they can run; their coordination is not implemented here.

## Isolated installation

`CameraStorage.Service.main_read/0` starts a separate nondistributed reader from
`VMS_ARCHIVE_READ_STORAGE_CONFIG`. It starts no repository, recorder, core
application or upload routes. The private listener authenticates a dedicated
client certificate pin and token; its single admission slot and ten-second
operation limit bound provider work and buffered bytes. Provider credentials
remain in that process. The listener accepts only the fixed binding and
destination and canonical init/media object-key families.

Web loads `VMS_ARCHIVE_READER_CONFIG`: schema version one, binding UUID,
destination SHA-256, and the installed private reader connection. That
connection contains the base URL and paths to its TLS certificate, key, CA and
token. It contains no provider key or provider endpoint. The reader installation
contains the original immutable destination, provider credential file reference
and its own listener TLS/authentication configuration. These are ServiceRadar
infrastructure credentials, not camera credentials.

This pass supplies a runtime entry point and synthetic validation, not a Helm
installation or Cloud readiness acknowledgment. Cloud must provision separate
read credentials and install the matching binding and identities through its
future lifecycle contract. The unresolved bucket ownership gate remains binding.

## Validation ownership

The existing Core archive owner checks exact range selection, limits, source
matching and canonical proof changes without writes. The storage-service owner
checks the real isolated listener, fixed destination, read/write identity
separation and bounded resource ownership. Existing egress tests own the full
HTTP range framing and TLS/CONNECT matrix.

The joined Web database owner publishes through the real upload service, removes
local inputs, stops recording and serves two independently invented fragments.
It changes persisted permission and proof state while provider bytes are in
flight, then proves that no bytes escape the final gate. Published-head guarded
Core/Web execution and successful fixture cleanup remain mandatory acceptance
evidence; compilation alone is not execution.
