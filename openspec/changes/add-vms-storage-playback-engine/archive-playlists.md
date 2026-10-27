# Bounded single-block archive playlists

This checkpoint exposes a finite HLS media playlist for a known published block.
It reuses canonical archive metadata and the [authorized fragment reader](archive-reads.md).
It does not discover recordings by wall-clock time, combine blocks, serve
provisional local media or enable recording. The [archive player](archive-player.md)
owns browser consumption and navigation.

## Request and representation

`GET /api/cameras/:camera_source_id/recordings/:id/playlist.m3u8` accepts two
optional query parameters: `first` (zero-based fragment index, default zero)
and `count` (maximum fragments, default 64). Both are canonical unsigned decimal
integers. `first` is at most 4095 and `count` is between one and 64. Leading zeros,
signs, lists and out-of-range parameter values return 400. A supplied HTTP Range
header also returns 400.

The window stops at the block's last fragment when fewer than `count` remain.
An empty window, more than 300 seconds of selected media, a selected fragment
larger than 4 MiB, an init object larger than 1 MiB, or a media object larger than
16 MiB returns 416. The playlist itself is limited to 64 KiB. Duration and byte
limits reject the request rather than silently shorten it. These are engineering
ceilings for this checkpoint, not measured production capacity objectives.

Success is always `application/vnd.apple.mpegurl`, with private/no-store and
nosniff headers. This fixed-representation download does not negotiate a Phoenix
rendering format; errors remain JSON. Its authentication, session, CSRF and
security plugs match the existing media API. The
[recording access policy](../../../docs/docs/rbac-and-roles.md#recording-metadata-and-footage)
owns required permissions and authority refresh; each request also checks fresh
Source access. Unavailable publication
returns 409; missing or wrong-camera blocks return 404; unexpected proof/database
failures return 503. Issuing a playlist performs no provider I/O or archive writes.

## Timing and authority

The serializer consumes one freshly proven canonical descriptor. Its selected
fragments share the descriptor's clock epoch and contiguous relative timing.
Integer nanoseconds become exact decimal seconds in EXTINF, without float
rounding. The target duration rounds the longest selected fragment upward to a
whole second. The media sequence is the first selected fragment's sequence.

The version-seven VOD playlist contains an initialization map and a finite end
marker. Relative `init` and `fragments/<index>` URLs identify complete bounded
resources. It emits no byte-range directives, provider addresses, credentials,
wall-clock mapping, cross-block continuity or independent-segment claim. Unknown
UTC remains unknown; publication time never becomes capture time. Tail-duration
provenance remains in the canonical metadata and is not upgraded by rendering.

A playlist is a snapshot, not a grant for its URLs. Each later init/fragment
request repeats the reader's fresh permission and proof checks, including its
post-provider release check. Revoked permissions and late proof conflicts can
therefore invalidate a previously returned playlist without leaking later bytes.

The wire format follows [RFC 8216](https://www.rfc-editor.org/rfc/rfc8216.html).
The existing byte gateway rejects client ranges; a consumer must request these
resources whole and obey the reader's current bounded admission capacity.

## Validation ownership

The pure serializer's database-free owner checks emitted wire bytes, exact
fractional durations, finite windows and resource ceilings. The existing joined
Web database owner checks real authorization/publication, response headers,
playlist URLs, denied requests and absence of provider work during assembly.
An independent consumer must decode packaged synthetic media fetched through
the real endpoint; hand-fed MSE coverage alone does not establish HLS behavior.

The joined consumer uses the existing pinned FFmpeg and FFprobe against a
loopback Endpoint listener. FFmpeg checks all three generated color intervals;
FFprobe requests only the middle fragment and checks its original media
timestamps. `seekable=0` and `http_seekable=0` disable Range probing;
`http_multiple=0` and `http_persistent=0` select sequential, nonpersistent
requests. Finite reload/retry counts and a five-second socket deadline bound
client failure. This is deliberate sequential-consumer coverage, not a claim
about default FFmpeg behavior or browser compatibility.

Remote author checks and actual published-head database execution remain separate
gates. Browser qualification is tracked in the [archive player](archive-player.md).
Cross-block seeking, live provider qualification and hosted deployment acceptance
remain open.
