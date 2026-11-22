# NVR media client

`ServiceRadarNVRClient.send_recording/4` sends one finite, already-authorized
capture to the private NVR ingest endpoint. This library has no Core, database,
Membrane or NVR application dependency and starts no service. It is intended for
the recording coordinator or agent/gateway media bridge; it does not select a
camera, acquire assignment authority or activate recording by itself.

Load installed workload credentials with `ServiceRadarNVRClient.Config.load/2`.
The JSON file has exactly `host`, `port`, `ca_file`, `cert_file`, and `key_file`.
Certificate paths are absolute. The separate token file contains 32 through 512
printable ASCII bytes without a trailing newline. The client verifies the server
certificate and hostname against the installed CA. These are ServiceRadar
workload credentials, never camera credentials. Invalid configuration refuses
the operation; there is no URL, redirect, credential or replica fallback.

Pass the string-keyed header defined in [the ingest contract](../../docs/nvr-ingest.md)
and a lazy enumerable of `%{payload: annex_b_bytes, sequence: n, pts: pts, dts: dts}`.
Timestamp units are 90 kHz. The caller supplies a total timeout of 1 through
300000 milliseconds (default 30000). The enumerable executes in an isolated
process and must acquire its own resources there; a caller-owned socket or
mailbox is not a transferable enumerable. Coordinators must provide bounded
media admission and source/writer authority covering the operation, and keep
the source consumer independent of viewers.

Frames are pulled and sent one at a time. The client enforces the 1 MiB unit and
64 MiB application-body limits, reserves room for the explicit end marker, and
bounds response headers/body and the entire worker lifetime. Normal enumeration
completion sends the end marker and HTTP EOF. Source failure, invalid access-unit fields,
caller loss or expiry never intentionally requests sealing. A blocked source or
socket cannot outlive the operation deadline, including after caller loss.

A successful response must identify the requested storage lifetime and exactly
the consecutive block keys derived from the original recording identity. The
result is `{:ok, %{status: :sealed_local, storage_id: id, block_ids: ids}}`. It is
local sealing evidence, not catalog, playback, preservation or deletion
authority.

The NVR refuses a stream by answering at once and no longer reading the body.
Before sending each chunk, up to and including the end marker, the client polls
the connection without blocking; after a failed send it makes one more
non-blocking read. When an answer has started it sends nothing more and reads
that answer within the same deadline and limits. A complete non-200 answer
read before the end marker went out returns `{:error, {:ingest_refused, status}}`:
a definite refusal of an unfinished stream, which cannot have sealed the block
the NVR had open (its journal stays unsealed). A non-200 answer after the end
marker returns `{:error, {:ingest_status, status}}` and does not rule out a
seal. A 200 before the end marker is `:outcome_unknown`, never success.
After transport, source or response-validation failure, `:outcome_unknown`
means partial or complete recordings may remain at the original NVR. The client
never retries media, increments the epoch or selects another endpoint. Discover
and reconcile retained blocks before authorizing any later operation.

## Archiving a sealed block

`ServiceRadarNVRClient.archive_block/4` asks the same NVR endpoint, with the same
installed CA, client certificate and bearer token, to copy one sealed local
block to an S3-compatible bucket (`POST /v1/blocks/<block_id>/archive`). The
caller passes the 64-character lowercase hex block id returned by ingest and a
string-keyed request with exactly `version` (1), `storage_id`,
`recovery_generation`, `destination` (`host`, `region`, `bucket`, `object_prefix`,
and an optional integer `port` that defaults to 443 and is named only for a
loopback peer)
and `credential` (`access_key_id`, `secret_access_key`). The client checks the
block id and the request shape and encodes the request as canonical JSON of at
most 8192 bytes before it connects; anything else returns
`{:error, :invalid_archive_request}`. The default total timeout is 120000
milliseconds (1 through 300000).

A 200 response must be a receipt for the same storage, block and destination
listing exactly `init.mp4`, `media.m4s` and `descriptor.json` under
`<object_prefix>/<storage_id>/<block_id>/`; the result is `{:ok, receipt}` with the
decoded string-keyed receipt. Unlike ingest, a non-200 response body is read and
returned as `{:error, {:archive_status, status, error}}`, where `error` is the
NVR's decoded JSON object (for example `%{"error" => "block_not_sealed"}`) or
`%{}` when the body is not one, so the operator can see why. A lost, truncated or
uncorrelated response is `{:error, :outcome_unknown}`. The client never retries.
Repeating the request is safe: the NVR returns an existing receipt for the same
destination and never overwrites an object.

The credential is held only for the request. No returned error, and nothing this
library logs, contains it. It is a bucket credential resolved by Core for this
one request, never a camera credential or an installed workload credential.

## Reading a sealed block's descriptor

`ServiceRadarNVRClient.block_descriptor/3` reads the canonical descriptor of one
sealed block (`GET /v1/blocks/<block_id>/descriptor`) over the same mutual TLS
and bearer token. The default total timeout is 15000 milliseconds (1 through
300000). The result is `{:ok, descriptor}`, the decoded string-keyed descriptor,
only when the 200 body is a valid descriptor, its canonical encoding is exactly
the bytes received, and its identity derives the requested block id; so a
caller that re-encodes it gets the NVR's bytes and digest. Any other 200 body is
`{:error, :invalid_descriptor_response}`. A non-200 answer is
`{:error, {:descriptor_status, status, error}}`, decoded as for archiving. A
lost, truncated or late answer, or one larger than the descriptor's 2 MiB bound,
is `{:error, :descriptor_unavailable}`. A malformed block id is refused before
connecting with `{:error, :invalid_descriptor_request}`. The read changes
nothing, so it can be repeated.

## Member status, block lookup and ledger pages

`status/2`, `lookup_blocks/3` and `block_page/4` read the member's observations
over the ingest listener with the ingest credentials. Each answer is checked
before it is returned: a lookup must report exactly the requested IDs in order;
a ledger page must hold ascending IDs after the cursor and name the last one as
`next_after` only when full; a block carries a descriptor digest exactly when
sealed and a reason exactly when unresolved. A failed check is
`{:error, :invalid_response}`; a non-200 answer is `{:error, {tag, status,
error}}` with tag `:member_status`, `:lookup_status` or `:inventory_status`; a
lost or late answer is `{:error, :unavailable}`. Callers compare the returned
`storage_id` with the member's configured storage. See
[member status and block state](../../docs/nvr-ingest.md#member-status-and-block-state).

## Reading media for playback

`ServiceRadarNVRClient.read_block/6` reads a sealed block's initialization bytes
(`:init`) or one fragment (`{:fragment, sequence}`) from an NVR's separate read
listener, so its configuration holds the read-purpose token and client
certificate, never the ingest ones. The caller passes the frozen descriptor's
SHA-256, which the NVR must match, and the expected `%{length:, sha256:}` of the
selected object (at most 1 MiB for init, 4 MiB for a fragment). `{:ok, bytes}`
is returned only when the body has exactly that length and digest. Errors are
typed for copy resolution: `:not_found` (404), `:integrity_mismatch` (409, or
bytes that differ from `expected`: the local copy is not the cataloged block),
`:unavailable` (503, transport failure or deadline), `{:read_status, status,
error}` for anything else, and `:invalid_read_request` before connecting. The
default timeout is 10000 milliseconds.

`ServiceRadarNVRClient.Members` loads an installed member map (`version`, `port`,
`ca_file`, `cert_file`, `key_file`, `members` of `host`, `storage_id` and an
optional `port`) with its token file, and finds the member that stores a given
storage UUID.

## Test ownership

The receiver's `//elixir/serviceradar_nvr:release_test` owns end-to-end transport
coverage. Its client cases run this library in an independent release VM,
exercise real mutual TLS, and independently decode NVR footage after restart.
An independent HTTP peer checks exact wire bytes, uncorrelated/malformed
receipts, server identity, no retries, aborted producers, mid-stream drops and
deadline cleanup. A real NVR refusing a stream mid-body checks that the client
reports `:ingest_refused` and stops sending.
The test-only release artifact is a harness for this library, not a deployed
recorder or a new service. Its probe's `archive` mode calls `archive_block/4`
with the request file's `block_id` and `archive_request`; its `descriptor` mode
calls `block_descriptor/3` with `block_id` and `timeout_ms`; its `status`,
`lookup` and `page` modes call `status/2`, `lookup_blocks/3` and `block_page/4`; its `read` mode calls
`read_block/6` and reports the length and SHA-256 of what it returned; its `paced` mode
sleeps `pace_ms` before each unit and reports how many units were pulled.
