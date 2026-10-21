# ServiceRadar Atlas membership protocol, version 1

The server evaluates bitmap queries. Browsers receive complete binary overlays
for the rows already admitted by the tile renderer. Membership never changes
ELK geometry or sends fleet-wide ID lists to the browser.

The manifest field `bitmap_membership_protocol: 1` enables membership on the
existing topology channel. `membership:watch` carries the bounded query and
exact admitted tile receipts. A client that sets `boundary_endpoints: true`
in the watch opts in to exact boundary endpoint counts; without it, every
boundary count stays zero, so older browser bundles keep their decoder
contract during rolling updates. Its reply binds dictionary epoch, query
digest, authority fingerprint and admitted-view digest; the view digest also
binds the boundary opt-in. `membership:frame` carries raw
binary. `membership:ack` carries the view digest and a decimal string sequence.
Membership receipts include only displayed geometry. Retained offscreen prefetch
can remain in the separate geometry watch without invalidating an unchanged
accepted membership view. A newly displayed receipt requires a matching complete
replacement before its filtered rows become visible.
A camera-only change (pan or zoom) that changes just the view digest keeps the
last validated view displayed until its replacement validates. Retained rows
expire 10 seconds after the first unconfirmed view change, and further camera
moves do not extend that deadline. A changed query digest, dictionary epoch or
authority fingerprint, a watch error, or a reset clears them immediately.
Membership watches start only for an explicitly selected query; even `{all:[]}`
is explicit. A null query keeps the authorized base map and its boundary clips
without waiting for index readiness. Clearing a query sends `membership:unwatch`
and releases its masks and pending work.

Each complete replacement may advance the source/index revision and index epoch.
Sequences are uint64, including values above JavaScript's safe integer range.
Older sequences and evicted views are ignored. A missing or mismatched receipt,
invalid state or changed authority clears membership and requests a baseline;
new tiles stay hidden until their entire admitted view validates. A sequence
jump is safe because every frame is a complete replacement.
Automatic retries cover transient warmup, source, and query failures. They use
a one-second exponential backoff capped at ten seconds. Malformed frames and
resets follow that backoff. A successful watch reply alone leaves the retry
count in place. An accepted complete replacement resets it. Unsupported
predicates stay explicit errors and stay out of that automatic retry. A new
query, a displayed view, a capability refresh, or another user request,
including a pan or zoom that invalidates the membership view, may submit the
same unsupported predicate again. Disable and teardown cancel retries.

## Binary format

All integers are little endian. Strings have a uint16 UTF-8 byte length and are
nonempty, at most 128 bytes, and contain no NUL. The whole frame is at most
256 KiB.

| Field | Encoding |
| --- | --- |
| Magic | Four bytes `SRMO` |
| Version | uint8 `1` |
| Kind | uint8 `0` full replacement, `1` reset |
| Reserved | uint16 `0` |
| Whole frame length | uint32 |
| Sequence | uint64 |
| Exact authorized query total | uint32; meaningful only for full replacements |
| Metadata | Seven strings in order below |
| Prefix freshness | uint8 count, at most 32, then each source string and uint64 version |

Metadata order is dictionary epoch, index epoch, query digest, authority
fingerprint, view digest, source revision, index revision. The fixed header is
24 bytes. Query totals come from the same captured index revision as the
complete replacement, never from summing tile counts. Pending, stale, rejected
and cleared views do not expose an old total.

The next field is named Prefix Tag freshness for this replacement: a uint8
source count, at most 32, then each source as a string and a uint64 catalog
version. Sources are strictly ascending raw UTF-8 bytes, with no duplicates.
A leading U+FEFF is part of the identifier.
An empty count means the query captured no named Prefix Tag. The same section
is present on a reset, which then ends. A later replacement may carry newer
versions while the watch binding stays unchanged. Versions are the captured
catalog versions for that sequence, not a cursor and not a second owner.

A full replacement then contains a uint8 tile count, at most 64, followed by
each tile:

| Tile field | Encoding |
| --- | --- |
| Tile z, x, y | uint8, uint32, uint32 |
| Exact revision | String |
| Row count | uint16, at most 128 |
| Matching flags | One uint8 per row, 0 or 1 |
| Causal state | One uint8 per row: root 0, affected 1, healthy 2, unknown 3 |
| Availability | One uint8 per row: healthy 0, unavailable 1, unknown 2 |
| Matching count | One uint32 per row |

Rows have the exact order of the receipt's geometry. Device counts are 0 or 1;
aggregate counts are the exact authorized query intersection and cannot exceed
the geometry row's represented population. A boundary row contributes no
geometry devices, but for an opted-in watch it may count 0 or 1: 1 only when
every relation through that portal reaches the same canonical remote device
and that device matches. Shared or unmapped portals count zero. A flag is 1 if
and only if the count is positive. Aggregate availability is unknown unless all
matching members share one state. Missing causal evidence stays unknown.

At 8192 admitted rows, column data is 57,344 bytes. Even maximum-length metadata
and tile receipts fit in a single 256 KiB frame, so there is no chunk assembly,
XOR history, browser bitmap codec, worker or secondary WASM heap. The decoder
retains views for the three byte columns and copies counts into aligned typed
arrays. Replacements release old arrays on eviction, disable and disconnect.
The renderer updates masks/colors/counts while retaining geometry attributes.
GPU upload remains a copy.

## Filtered requests

Search, details and the latest scene snapshot carry the active expression as the
bounded `query` parameter. A request whose encoded target stays within 8,000
characters uses GET, including every request without a filter. A valid expression
that would exceed that request line uses POST to the same path, with a JSON body,
the existing CSRF token and the same authorization. The expression budget stays
16 KiB. These bodies are not a server query cache, and the filter is not stored
in the map-share URL. This JSON is control metadata, not a bulk ID transport.
Each request evaluates current membership; page cursors bind query, authority
and dictionary continuity. The browser discards responses from older local
query generations and does not reuse filtered scene cache entries. Unsupported
filtered scenes report an error instead of opening an unfiltered scene.
Relations and packet animation require full represented membership at both
endpoints while a query is active; a boundary endpoint is complete at a count
of 1 and is never drawn or picked as a device. A partially matched aggregate has no filtered
relation or traffic estimate until the server can evaluate the exact relation
intersection. Its full bundle is never presented as the query's relation.
Unsupported boundary rows and unmapped geometry remain excluded, and the
watch projection receipt reports incomplete canonical identity coverage.

## Binary health and traffic

The manifest field `world_overlay_protocol: 1` also switches each existing
`/topology/overlays/:layout/:z/:x/:y` request to
`Accept: application/vnd.serviceradar.world-overlay`. The server returns that
content type and an SRTO version-1 frame. An enabled Atlas always advertises
this protocol, and the client rejects a JSON response.

All SRTO fields are little endian. Its 12-byte header contains `SRTO`, version
uint8 `1`, flags uint8 `0`, reserved uint16 `0`, and whole frame size uint32.
The following fields appear in this order:

| Fields | Encoding |
| --- | --- |
| Layout, tile ID, tile revision, health world revision, health tile revision | Five bounded strings, as above |
| Generation, health epoch, health revision, observation sequence | Four uint64 values |
| Response and health sample timestamps | Two nullable timestamps |
| Source status, reconciling, pending | uint8 enum (stale 0, seeding 1, refreshing 2, current 3), uint8 boolean, uint32 |
| Last read, reconciled since | Two nullable timestamps |
| Source observed and total | Each uint8 present flag followed by uint64 (zero when absent) |
| Rendered relations, selected relations, candidates examined, requested pairs, queried pairs, omitted pairs | Six uint32 counts |
| Scan complete | uint8 boolean |
| Query since, until, fresh after | Three nullable timestamps |
| Window seconds, freshness seconds, timeout ms | Three uint32 values |
| Node and edge count | Two uint16 values, at most 128 and 512 |
| Health rows | Five uint64 counts: healthy, unavailable, unknown, observed, total |
| Flow rows | Fixed 220-byte records below |

Each flow record starts with uint32 total and selected relation counts, then
seven uint32 eligibility counts in this order: physical, ineligible,
not_physical_evidence, excluded_role, missing_interface_binding,
shared_interface, unselected. Forward and reverse each contain 92 bytes:

| Direction fields | Encoding |
| --- | --- |
| Status, animate, reserved | uint8 (unknown 0, partial 1, measured 2), uint8 boolean, uint16 zero |
| Packet total, observed packets, observed octets, octet total rates | Four float64 values |
| Packet and octet observed relation counts | Two uint32 values |
| Packet interval, octet interval | Each three nullable timestamps: previous, earliest, latest observation |

Unknown rates use exactly the quiet-NaN bits `0x7ff8000000000000`; a measured
zero remains zero. Other nonfinite or negative rates are invalid. Timestamps
are signed int64 Unix microseconds; `INT64_MIN` means absent. An interval is
either wholly absent or has all three timestamps. The browser retains exact
timestamps as BigInt, health epochs as their native 16-character lowercase hex
strings, and revisions/sequences as decimal strings. String decoding preserves
a leading U+FEFF as identifier content, as it does for SRMO. Counts
must remain exactly representable in JavaScript.

Native health selections and flow summaries preserve the Arrow node/edge row
order. IDs are omitted from the row records. The decoder validates the exact
layout, generation, tile revision, row counts, and represented edge counts
before publishing. It retains a DataView and reads row fields on demand,
without expanding every tile into persistent nested edge/interval objects.

Frames are limited to 256 KiB; the maximum row population with 128-byte metadata
strings is below 128 KiB. Four requests may be active. The enabled client caps
retained telemetry at 5 MiB, accounting for actual backing buffers, 8 KiB per
tile for metadata, and 128 bytes per edge for existing CPU/GPU packet attributes.
Another 3 MiB is reserved for bounded HTTP assembly, membership and temporary
decoding/packing. Before fetching, the client admits displayed tiles in stable
numeric z/x/y order using their maximum encoded row size plus those allowances.
Tiles outside the budget remain unknown until admission changes; a stationary
dense view does not repeatedly fetch and evict the same omitted telemetry. Geometry
has its own cache budget. Disabling, eviction and failed samples release
telemetry, while generation changes discard late replies.

The browser-codec experiment and its tradeoffs are recorded in
[topology bitmap measurements](topology-bitmap-measurements.md).
