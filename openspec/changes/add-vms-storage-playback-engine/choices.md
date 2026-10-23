# Implementation choices

## Sound, medium confidence

### Exercise the real receiver through a bounded test binary

When: synthetic RTSP feasibility pass.

The package test binary reaches the private Go receiver without adding a public
production API. A real loopback RTSP server supplies newly generated media; the
owning default RBE ExUnit suite packages the observed chunks and independently
decodes recovered bytes. Four sequential captures allow at most 90 access units
and 1 MiB of source each, with 8 MiB total output, finite socket/capture deadlines
and a 60-second action ceiling. FFmpeg uses one thread.

The plan required synthetic RTSP proof but did not select a cross-language
harness. This is sound because receiver timebase and sequence are measured,
including RTP wrap. A failed TCP source is followed by an explicit fresh receiver;
the harness supplies a new recorder epoch and unknown UTC mapping. This does not
claim automatic manager reconnect or authenticated gateway recovery. The small
push-all assertion helper stays local to each independent test module instead of
making the media generator own packaging execution.

### Probe the provider through the existing release

When: storage endpoint feasibility pass.

The opt-in diagnostic uses the production release with an empty release config,
so its executable startup needs no database or deployment credentials. Requests
are bounded to two fresh unversioned buckets, a small object, one multipart
object and an aborted multipart upload. A durable, directory-synced receipt
precedes each external mutation. A finite recovery pod reads the receipt from
the dedicated PVC even when the probe fails. Operator cleanup owns the exact
fresh resources and verifies their absence; it never adopts existing buckets.

The plan required a live endpoint probe but did not choose the harness or its
limits. It admits at most 80 probe requests plus 30 cleanup requests, 64 MiB of
request bodies with 2 MiB reserved for cleanup, and 15 minutes plus three minutes
of cleanup. The job has a 20-minute deadline, two CPUs, 512 MiB of memory and
128 MiB ephemeral storage. These are experiment bounds, not performance promises.
Version drift fails cleanup rather than permitting recursive deletion. The
diagnostic always reports Cloud readiness false: provider-scoped keys still have
more authority than a recorder, and policy/Object Lock are separate gates.

### Adopt an existing stream without granting stale recorder rights

When: relay lifecycle integration.

An authenticated stream may regain ownership after its previous owner lease
expires, but only when its camera/profile has no different binding or competing
live relay. Adoption increments the owner epoch. A recorder holding the old epoch
must stop; it cannot silently retrieve the new fence and continue publishing.

The plan required one ingest and preserved live viewing, but did not specify how
an already running stream joins the new ownership model. This is sound because
adoption serializes with new opens, validates the persisted assignment and does
not inherit consumer leases. During a mixed-version rollout, old binaries can
still create legacy duplicates. Ambiguous authenticated legacy streams may keep
heartbeating until that ambiguity clears, but cannot admit new consumers or
recording. Once a current binding exists, it is authoritative. These transitions
still require the guarded database race tests before deployment.

### Renew viewers in batches and reclaim expired consumers by index

When: relay lifecycle integration.

The authoritative viewer registry renews distinct viewer identities at heartbeat
cadence, under one owner fence. Each SQL batch contains at most 256 rows; a final
database-time check rolls back the whole operation if ownership expires. Work
still grows with admitted viewer count. This pass does not invent a new viewer
quota or perform a database write for every video frame.

Cleanup reads one indexed batch ordered by expiry and ID, then rechecks each row
under its owner lock before deletion. Consumers from older epochs remain until
their bounded expiry, at most five minutes after their last acquisition or
renewal, without keeping the new owner alive. The plan required bounded cleanup
but did not select this query shape. It is sound because the expiry index bounds
candidate retrieval without an unbounded join over old epochs. A registry restart
still loses its ephemeral viewer membership; rebuilding that membership is a
separate existing recovery limitation, not speculative replay in this pass.

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
processing stays outside its transaction. Lifecycle cleanup reclaims expired
consumer rows in indexed batches; desired consumers must be acquired again after
takeover.

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

### One local block before archive-driven rotation

When: recorder worker pass.

The disabled recorder first writes one finite local block and stops when its
capacity is reached. It seals previously committed fragments on ordinary
capacity stop; queue failure or lease expiry does not claim a successful seal.
It never deletes media or silently starts another block. Four active workers
per node and eight queued access units per worker are provisional experiment
limits, not measured deployment capacity. Each queued payload is independently
bounded to 1 MiB, with an additional byte budget.

The plan did not fix initial worker sizing or an archive reclamation policy.
This choice is sound for a disabled integration path because it exercises real
durability and failure boundaries without inventing retention behavior. Global
spool capacity across stopped epochs, rotation, archive acknowledgement and
reclamation remain prerequisites for enablement; the active-worker cap alone
does not bound accumulated files.

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

### Keep recovery metadata separate from archive verification

When: manifest wire-contract pass.

A versioned manifest describes exactly one sealed single-track baseline H.264
block. It carries clock provenance, verified-local fragment offsets and hashes,
and remote object identity receipts. Its relative keys derive only from source,
profile, recorder epoch and block sequence. Retrying different clock metadata or
bytes therefore cannot evade a conflict by choosing a new key. Deployment storage
bindings and credentials stay outside the manifest.

The plan required recovery metadata but left its encoding open. Canonical JSON
with a 2 MiB ceiling, exact version/field validation and the spool's finite
absolute limits is sound for the first supported format. Missing motion analysis
is unknown. Decoding requires an expected persisted identity; it neither grants
access nor proves remote bytes. The uploader must still verify init, media and
manifest before the index transition. Recovery after the recorder's release
needs a separate durable historical block authority; a current recorder lease
alone cannot authorize it.

### Admit recording work before mailbox enqueue

When: recorder worker pass.

The existing relay pipeline remains the one producer. An atomic reservation
checks both queued bytes and sample slots before copying and sending a media
unit to its recorder. The worker returns those credits only after packaging and
storage finish. Overload closes that recorder's admission once while the same
chunk still goes to the existing live path. Producer-ordered end-of-stream can
drain admitted units; a producer crash without that boundary cannot do so.

The plan required independent backpressure but left the process boundary open.
This choice is sound because a slow disk cannot turn an unbounded worker
mailbox into hidden storage or block the global relay manager. Only one local
pipeline pid may use a handle, and a terminal handle cannot become readable
again through the end-of-stream transition.

### Acquire real configuration and a keyframe when joining live ingest

When: recorder worker pass.

Recording can start between keyframes. The worker enables a bounded initial
wait in the native H264 parser for real in-band parameter sets and an IDR;
the wire's keyframe hint cannot establish either. Every skipped input still
consumes cumulative byte and sample limits, and both media time and wall time
bound acquisition. Once acquired, codec changes or malformed units stop the
recorder. Cameras supplying parameter sets only through SDP need a separately
proved transport contract; this pass does not manufacture that information.

This is sound because joining a working live stream does not require restarting
it, while unsupported or incomplete input cannot wait or grow state indefinitely.
Strict standalone packaging remains the default for callers that already own
an independently decodable start.

### Conservative lease time and bounded teardown

When: recorder worker pass.

The worker owns a recorder consumer lease independently of viewers. Its local
deadline is the monotonic time at request start plus the database's remaining
lease duration. Time spent in a database request therefore shortens local
admission. Checks before and after disk work withhold a new readable receipt if
the lease expires during that work; committed bytes remain for fenced recovery.

Consumer release and captured-relay idle close are a separate best-effort step.
One linked task belongs only to its stopping worker, which traps exits, waits
up to one second and then forcibly shuts the task down. The worker cap bounds
these tasks. Elixir 1.19.1 Task.Supervisor task admission itself waits without a
timeout, so introducing a shared task supervisor would not establish the stop
bound. Failure to start or finish cleanup falls back to lease expiry/reaping and
never changes the media seal result. This is sound because cleanup cannot hold
live media delivery or reopen a stale ownership epoch.

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
