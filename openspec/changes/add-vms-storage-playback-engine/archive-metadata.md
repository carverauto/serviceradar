# Authorized archive metadata

`GET /api/cameras/:camera_source_id/recordings/:id` inspects one retained block.
It is a metadata API, not a timeline search, playlist or media delivery endpoint.
Recording remains disabled by default.

## Authorization and identity

The [recording access policy](../../../docs/docs/rbac-and-roles.md#recording-metadata-and-footage)
owns required permissions, role defaults and per-request authority refresh.
A shared link does not confer access.

The source is read under that refreshed user scope. Only then may the controller
use the internal archive reader. That reader matches the retained block's source
inside the existing block/proof transaction before reading its archive state.
A missing block and a block from another camera both return `recording_not_found`
with HTTP 404. Invalid UUIDs return 400, absent authentication 401, and denied
current permission 403. An unreadable proof chain returns the bounded 503 error
`archive_metadata_unavailable`; internal errors are not returned to the caller.

## Response contract

The JSON `data` object has exactly seven fields:

| Field | Meaning |
| --- | --- |
| `schema_version` | `1` |
| `block_id` | Requested retained block |
| `camera_source_id` | Authorized, matched source |
| `stream_profile_id` | Retained capture profile |
| `archive_status` | Current canonical publication phase, or `unavailable` for an unfrozen/unbound block |
| `published_at` | Publication timestamp only while available; otherwise null |
| `descriptor` | Frozen version-one descriptor only while available; otherwise null |

The existing descriptor validator bounds metadata to 2 MiB and 4,096 complete
fragments. Its codec, byte intervals, digests, media clock and unknown UTC/motion
values remain unchanged. The response contains no destination, bucket, object
key, URL, credential, upload token, dispatch ID or verification receipt.
Responses reaching the controller use `Cache-Control: private, no-store`.

## Canonical availability

`ArchiveUploads.archive_metadata/3` uses the same proof joins and publication
phase as `publication_status/2`. It locks the block then init, media and manifest
proofs in the established order. A historical publication timestamp alone never
exposes the descriptor. If a late observation conflicts, the next read returns
`reconciliation_required` with null descriptor and publication time; the retained
publication receipt remains intact for internal audit and recovery.

Reads acquire no upload lease, renew no authority, modify no recording row and
make no provider request or local spool access. Database locks last only for the
bounded metadata read. One block per request and the existing API rate limit
bound this checkpoint's surface; measured fleet query/capacity objectives remain
open. A returned snapshot can become stale immediately. The
[archive byte routes](archive-reads.md) independently authorize the caller,
requested interval and current proof state; this response is never a bearer
capability.

## Validation ownership

The existing joined Web database owner extends real synthetic media/init/manifest
publication with authenticated HTTP metadata reads. It checks the exact public
shape, unbound state, mismatched camera, late conflict and unchanged provider
traffic/lease state. Existing camera controller tests own authentication,
permission separation, current-role revocation and invalid identities. Every
prior publication assertion remains. Test-owned committed users and archive rows
must be deleted and re-queried by teardown.

Run remote unit/quality/registration checks, then require published-head guarded
Core and Web suites including connection observation, teardown and generation
lease release. Compilation alone does not complete this contract. This slice
does not close task 1.5: [archive bytes](archive-reads.md) and
[bounded HLS playlists](archive-playlists.md) have their own contracts and
validation owners. Provisional local playback, timeline discovery and the
player remain separate work.
