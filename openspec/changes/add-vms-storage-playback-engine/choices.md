# Implementation choices

## Sound, medium confidence

### A bounded connection per object range

When: authenticated range transport pass.

When playback requests a byte interval, the HTTP client opens one connection,
requires the real partial-response status and matching object identity, buffers
only the authorized interval, and closes the connection. It returns no bytes
until the complete response length and headers are validated. The caller must
supply an interval ceiling, the whole-object size, and a strong ETag or version.

The plan required secure bounded ranges but left the transport ownership open.
The existing full-download client intentionally rejects partial responses, and
its streaming transport does not expose the status needed to distinguish a
whole-object fallback. The range API therefore uses already-pinned Mint 1.11.0,
with both direct TLS and explicit CONNECT proxy coverage. Full downloads retain
their existing transport. No new library version or shared pool is introduced.

Header sections are capped at 16 KiB. Connection phases have timeouts, and the
response has a separate fixed 30-second default deadline that does not restart
when bytes arrive. This is sound for bounded ownership and late-error handling;
connection reuse, provider header compatibility and playback throughput remain
measurement gates. A connection per interval has handshake cost and is not a
claim that the playback latency target has been met.

### Bound owner leases and reserve idle close

When: durable ownership pass.

If the final viewer leaves while a recorder is still using a camera, its
independently expiring consumer lease keeps the ingest alive. When no live
consumer remains, a database transaction reserves closure and captures the exact
relay ID. A viewer arriving after that reservation cannot attach to a stream
already being closed. If the closer crashes, the reservation expires within five
seconds so another owner can recover it. Ordinary owner and consumer leases have
a five-minute maximum and use database time rather than competing node clocks.

The plan required independent leases and fencing but left their initial limits
and the close reservation shape open. These limits bound abandoned work without
adding another heartbeat service. They need deployment timing measurements before
hosted enablement. The durable owner row survives release so a later process
cannot reset its generation counter. A process must use a fresh opaque owner
token on each incarnation; a reused machine name is not a process identity.

This is sound because closure and attachment serialize on one row, while media
processing stays outside its transaction. Future lifecycle code must reclaim old
consumer rows in bounded batches and reacquire desired consumers after takeover.

### Keep publication transactions short and recheck expiry

When: durable ownership pass.

An uploader can finish writing an immutable object after its camera owner loses
its lease. It cannot make that footage available by publishing old metadata:
publication locks the owner row, checks the generation and token, performs only
CNPG work, then checks database time again before commit. A lease that expires
during the callback rolls the metadata transaction back.

The plan specified a fence but not the exact callback boundary. This choice adds
a second database read for publication so a callback cannot commit on an expired
lease. The transaction cannot make S3 writes atomic and must never contain network
or filesystem work. This is sound because immutable object names isolate stale
uploads, while the database controls which objects become available. Integration
tests for the actual database races remain a required gate.

### Local journal format and provisional sizing

When: local spool pass.

When a fragment finishes, the spool writes its media bytes and asks the operating
system to sync them, then does the same for a small checksummed journal record.
Only the returned byte map makes that fragment readable. After an interrupted
write, recovery checks each complete record and its media digest before removing
an unfinished tail. A complete corrupt record stops recovery instead of silently
discarding footage. A final journal record seals the block; renaming a file is
not the commit boundary.

The plan required this ordering but left the journal encoding and initial limits
open. The implementation uses bounded JSON records with length prefixes and
SHA-256 checksums. Initial defaults are 8 MiB per fragment, 64 MiB per block,
512 fragments, and 10 seconds per fragment; these are conservative experiment
settings, not measured deployment capacity or performance promises. Deployment
profiling can lower or raise them within explicit ceilings.

This is sound because recovery and playback consume the same committed byte map,
and all reads, records and block sizes have finite limits. The filesystem must
support file and directory sync. The guarantee covers the local node only;
another node cannot recover footage that never reached an archive.

## Sound, high confidence

### Preserve unknown clock mappings

When: local spool and packaging boundary.

A camera can supply media timestamps without establishing what time of day they
represent. The packager carries an explicit unknown UTC mapping in that case,
and the spool preserves it. It does not substitute the server's current time.
When a mapping is available, its media origin and uncertainty travel with the
recording. This enables later timeline code to distinguish established capture
time from incomplete clock evidence.

The plan required honest clock provenance but did not fix the in-process shape.
The packager owns clock validation; storage persists a bounded copy of that
context. Disk block names depend only on source, profile, recorder epoch and
block sequence. Changing clock metadata cannot create a second copy of the same
block identity. This is sound because an unsupported clock claim stays visible
instead of becoming a false timestamp in exported evidence.
