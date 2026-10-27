# Bounded archive publication inventory

`GET /api/cameras/:camera_source_id/recordings` lists currently available
published blocks for one camera, newest publication first. This is a publication
inventory, not a capture-time timeline. Publication time never becomes capture
time; the recorder's unknown UTC mapping remains unknown. Recording stays
disabled. The [archive player](archive-player.md) owns inventory browsing and
playback without opening a live relay.

## Request and response

The existing authenticated JSON API and default rate limit own the route.
Every page requires fresh `devices.view`, `devices.cameras.recordings.view` and
Source access, following the [recording access policy](../../../docs/docs/rbac-and-roles.md#recording-metadata-and-footage).
Live-video permission alone is insufficient. Missing authentication returns 401,
denied authority 403, malformed identities or page parameters 400, and missing
sources 404. Unexpected database/proof failures return sanitized 503 errors.
Responses reaching the controller are private/no-store and nosniff.

`limit` is a canonical unsigned decimal integer from one to 20, default 10.
It bounds candidates examined, not the number of available items promised.
`cursor` is an optional opaque continuation returned by the previous page.
Malformed, empty, list-valued, oversized or other-camera cursors are rejected.
A cursor is at most 512 bytes; its versioned base64url JSON retains the source,
publication timestamp with microsecond precision, and block UUID. It carries
ordering state only, never permission or a storage location.

The JSON `data` object contains `schema_version: 1`, `items`, and `next_cursor`
(string or null). Every item contains exactly `block_id`, `camera_source_id`,
`stream_profile_id`, and `published_at`. The timestamp labels publication only.
Select an item through the existing [metadata](archive-metadata.md) and
[playlist](archive-playlists.md) routes; both independently reauthorize it.
Descriptors, provider locations, credentials, verification receipts and byte
access grants are absent from inventory responses.

## Bounded work and availability

Candidates have a matching camera and non-null publication timestamp. The query
orders `(archive_published_at, id)` descending, fetches at most `limit + 1`
identities, and uses the extra row only to detect another page. A partial B-tree
index on camera, publication timestamp and UUID supports this order without
loading the recording descriptor into the candidate page.

Only the first `limit` candidates are checked, serially, through canonical
`ArchiveUploads.archive_metadata/3`. Each check owns its existing short
block/proof transaction; no transaction spans the whole page. Only available
results produce summaries. A late conflict can therefore hide a historically
published block without deleting its retained publication history. Proof errors
fail the page rather than masquerade as an empty successful result.

When lookahead exists, the cursor advances past the last candidate checked,
including an unavailable candidate. An empty `items` array can therefore have a
non-null `next_cursor`; clients continue until the cursor is null. There is no
refill scan or total count. A new publication after a page was read is discovered
by refreshing from the first page. This is ordinary keyset navigation, not a
transactional snapshot across pages. Each returned item is an availability
snapshot and grants no future access.

Reads do not touch a provider, local spool or upload lease. The 10/20 candidate
bounds are engineering limits, not measured production query-capacity claims.
True capture-time filtering awaits trusted clock mappings and uncertainty
semantics. Browser HLS seeking and cancellation belong to the
[archive player](archive-player.md); provisional local delivery, retention,
provider qualification and hosted enablement remain separate gates.

## Validation ownership

The existing Core publication owner proves deterministic pagination, equal-time
UUID ordering, exclusion of unpublished and other-camera rows, advancement over
unavailable candidates, and invalid cursor/internal-actor refusal. It uses real
synthetic publication chains, not manually stamped availability. Existing Web
owners prove routed authorization with stale cached grants, exact compact JSON,
query rejection, publication/late-conflict transitions and unchanged provider
traffic and retained rows. Every prior assertion remains mandatory.

Run remote unit/quality/registration checks and require actual published-head
Core/Web database execution with successful observer, teardown and generation
release. Compilation and prepublication remote checks do not establish database
behavior. This checkpoint does not close the complete timeline/player task.
