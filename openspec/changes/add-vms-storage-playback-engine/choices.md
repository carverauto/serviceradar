# Implementation choices

## Sound, medium confidence

### Isolate the A/V diagnostic and bound its cost

When: Stream Doctor feasibility pass.

The diagnostic runs the upstream integrity-pinned Linux/x86-64 daemon in a
test-only process. Its bundled dependencies differ from the product's pins, so
the test does not change the shared media stack. Two sequential cases share one
daemon but use separate viewers and metric collectors. Ten decoded samples from
an 18-second synthetic source must appear within finite deadlines; missing data
cannot count as zero drift.

The plan required a working delayed-stream control but did not choose tolerances
or resource limits. The test uses the upstream example's 50 ms quality tolerance
and a 500 ms injected delay. It allows 1 GiB of sampled scratch space because
the fixed daemon runtime expands to about 481 MiB. The watchdog is not a hard
filesystem quota. These are sound diagnostic settings with measured separation
between control and fault, not production synchronization or capacity promises.
Long-term drift, ARM64 support and ServiceRadar's own audio path need separate
proof. [The diagnostic evidence](stream-doctor.md) owns exact pins and bounds.

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

### Provisional packaging capacity

When: bounded CMAF packaging pass.

The packager initially admits at most 1 MiB per access unit, 8 MiB of buffered
media, 1,024 buffered samples and an 8 MiB fragment. Its target segment duration
is two seconds, with independent five-second media and ten-second wall-clock
keyframe bounds. Trusted configuration may adjust them within finite ceilings.
These are experiment settings, not a claim about deployed camera capacity.

The plan required bounded work but did not choose initial values. This is sound
because each bound can stop only its recorder and measurements can replace the
defaults before live capacity acceptance. The separate byte, sample and time
limits prevent a missing keyframe from growing memory or waiting indefinitely.

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

### Baseline-only admission without fabricated decode timestamps

When: bounded CMAF packaging pass.

The first recorder accepts baseline or constrained-baseline H.264, one complete
AnnexB access unit per call, and an explicit clock epoch and tick rate. It rejects
other profiles, unequal PTS/DTS, timestamp resets and changed codec initialization.
Equal timestamps alone cannot establish that a camera never reorders frames.
The existing wire does not carry an independently established decode clock for
B-frames, so other profiles need a later clock and codec contract.

The plan allowed a narrow admission contract while codec compatibility remained
unproved. Restricting admission is sound because unsupported footage fails
explicitly without changing the already working live stream. Reconnect and
configuration changes require a new packager instance and recording epoch.

### Complete segment bytes own the fragment contract

When: bounded CMAF packaging pass.

One owning process pushes one access unit and consumes its returned events before
pushing another. Ordered pipeline events acknowledge that unit only after parsing,
muxing and the output sink. This bounds work without a second unbounded mailbox.
The caller owns storage receipts; the packager returns init and fragment bytes,
hashes, independently decodable sample boundaries and verified media timing.

The existing pins are retained: h26x 0.10.9 and MP4 0.36.10 with their format
packages. MP4 0.36.10 does not reset its chunk-duration accumulator in the
whole-video-segment path, so its `last_chunk?` metadata can remain false for a
complete segment. The sink uses only whole-segment mode and verifies the parsed
sample table, keyframe flag and exact media length instead of trusting that flag.
This is sound because the emitted bytes define the storage boundary; an
independent parser and decoder can reject an incorrect boundary.

When end-of-stream flushes a tail, the pinned muxer infers the final sample's
duration from the preceding sample. The packager rejects a one-sample tail and
labels the remaining inference `previous_sample`; the journal and recovered map
preserve that qualifier. Nanosecond durations subtract converted endpoints so
rounding cannot introduce a one-nanosecond gap between adjacent fragments.

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
