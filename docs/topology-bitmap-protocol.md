# Topology membership protocol, version 1

The server evaluates bitmap queries. Browsers receive complete binary overlays
for the rows already admitted by the tile renderer. Membership never changes
ELK geometry or sends fleet-wide ID lists to the browser.

The manifest field `bitmap_membership_protocol: 1` enables membership on the
existing topology channel. `membership:watch` carries the bounded query and
exact admitted tile receipts. Its reply binds dictionary epoch, query digest,
authority fingerprint and admitted-view digest. `membership:frame` carries raw
binary. `membership:ack` carries the view digest and a decimal string sequence.

Each complete replacement may advance the source/index revision and index epoch.
Sequences are uint64, including values above JavaScript's safe integer range.
Older sequences and evicted views are ignored. A missing or mismatched receipt,
invalid state or changed authority clears membership and requests a baseline;
new tiles stay hidden until their entire admitted view validates. A sequence
jump is safe because every frame is a complete replacement.

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
| Metadata | Seven strings in order below |

Metadata order is dictionary epoch, index epoch, query digest, authority
fingerprint, view digest, source revision, index revision. Reset has no payload.
A replacement contains a uint8 tile count, at most 64, followed by each tile:

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
aggregate counts are the exact authorized query intersection. A flag is 1 if
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

Search, details and scene requests carry the active expression as the bounded
`query` URL parameter. This JSON is control metadata, not a bulk ID transport.
Each request evaluates current membership; page cursors bind query, authority
and dictionary continuity. The browser discards responses from older local
query generations and does not reuse filtered scene cache entries. Unsupported
filtered scenes report an error instead of opening an unfiltered scene.

The browser-codec experiment and its tradeoffs are recorded in
[topology bitmap measurements](topology-bitmap-measurements.md).
