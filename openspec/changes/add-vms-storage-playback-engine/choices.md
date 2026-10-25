# Implementation choices

## Sound, medium confidence

### Establish media authentication before storage authority

When: deployment-scoped media authentication pass. Verdict: sound, medium confidence.

When Cloud replaces an environment, its account-level password-reset token can
remain unchanged. Media operations now require a separate installed credential
and exact deployment identity, including on the existing receipt API. The
installation endpoint reports which process answered, while keeping readiness
unavailable. This closes a real access boundary without treating an installation
acknowledgment as storage permission. Full desired/applied content, fresh evidence
and isolated provider credentials remain required before execution.

### Replace processes when installation identity changes

When: deployment-scoped media authentication pass. Verdict: sound, medium confidence.

Pods read their token at startup. The chart puts the deployment reference and
generation on the pod template so changing either requests replacement pods.
Updating Secret bytes alone leaves old processes able to use their loaded token.
This pass does not build a rotation workflow or claim that one successful
acknowledgment means every old replica has stopped. Cloud must observe retirement
before it can report complete revocation in a future lifecycle pass.

### Receive qualification claims before installing storage authority

When: private qualification receipt pass. Verdict: sound, medium confidence.

A provisioner can submit an all-passed report while the runtime still lacks a
storage workload, current evidence or an authenticated environment identity.
The receipt API records that submission and returns unavailable status with
no applied revision. The receipt pass used the account-scoped private credential;
the media authentication pass replaces that ingress with a deployment-scoped
credential, without upgrading historical receipts into authority. The plan required
an authenticated desired/applied exchange but did not select its implementation
sequence. Keeping this receipt sub-contract explicit lets that exchange gain a
real durable ingress without inventing authority or a second credential system.
Full desired configuration and environment-bound fresh installation remain
separate requirements, and future code cannot promote these receipts unchanged.

### Keep one current receipt and retain withdrawal ordering

When: private qualification receipt pass. Verdict: sound, medium confidence.

If revision two withdraws a report and a delayed revision one arrives afterward,
the runtime retains revision two and refuses the older request. An exact retry
of the current revision returns its original receipt and arrival time. The plan
required stale/conflict handling but left storage shape open. A current row per
binding, serialized under the existing binding lock, provides that order without
an unbounded history. Withdrawal clears the report but retains its revision; it
claims no provider revocation. Evidence history stays with the producer's named
evidence bundle. Callers needing a historical audit must not treat this current
row as one.


### Retain the received report without turning it into evidence verification

When: private qualification receipt pass. Verdict: sound, medium confidence.

If a report claims an encrypted upload passed, the current row retains that exact
validated report, not just its digest. A future installer can inspect the claim
but must still verify its evidence and freshness through the required exchange.
The plan did not choose what a receipt stores. The report is marked sensitive and
is not echoed by the API; replacement or withdrawal removes the old report.
Expired or failed observations remain acceptable claims. Retention does not make
them current or true, and no expiry cleanup process is introduced.

### Keep revision enforcement at the submission owner

When: private qualification receipt pass. Verdict: sound, medium confidence.

Two concurrent callers must compare revisions under the same retained-binding
lock before either changes the receipt. `ArchiveQualifications` owns that whole
operation; the Ash receive/replace actions are trusted persistence primitives.
The plan left that ownership boundary open. Future callers must enter through
the coordinator instead of writing the resource directly. This fits existing
Ash ownership without a second revision implementation in a database trigger.

### One evidence bundle for an exact qualification context

When: qualification report pass. Verdict: sound, medium confidence.

The plan required attributable observations but did not choose their serialized
shape. When a provisioner reports a successful encrypted write and a failed
missing-header denial, both results remain in one report beside the destination,
credential generation, policy and storage-service identity. A required reference
names the evidence bundle for that exact context. Nineteen fixed check names keep
these claims bounded and prevent a producer from omitting an inconvenient check.
Grouped checks mean the producer must prove every criterion in the group; a
partial result cannot be called passed. Separate evidence references per check
would add a second attribution structure without changing that obligation.

Future producers must retain the complete referenced evidence and authenticate
the report. The format cannot establish whether that evidence exists or whether
the claims are true. Protection-mode evidence and the full readiness assessment
remain separate work; these nineteen observations cannot enable recording.

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
stay inside two fresh unversioned buckets. The original controls are a small
object, one large multipart object and an aborted multipart upload. Conditional
writes and explicit SSE-S3 add exact keys inside the same limits; the
[provider runbook](../../../build/media/provider-probe.md) owns that inventory.
A durable, directory-synced receipt
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
uploads, while the database controls which objects become available. Guarded
ownership execution is recorded in [the handoff](README.md). Integration tests
for these publication races remain a required gate.

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

### Limit the first positive authority to one short init-only installation

When: init-authority checkpoint. Verdict: sound, medium confidence.

When a storage process starts, it can request a fresh challenge for one complete
configuration. An administrator has at most 30 seconds from that request to
apply it; a granted init upload has at most five seconds and one MiB of media.
These are checkpoint ceilings, not recording capacity targets. The plan required
fresh positive authority but did not choose its first executable scope or these
bounds. Keeping the window nonrenewable makes replay, restart and lost-response
behavior testable before continuous recording exists. A long-running installation
protocol still needs its own implementation and capacity measurements; this
checkpoint must not become an undocumented production renewal loop.

### Keep the configuration and evidence identity in one complete document

When: init-authority checkpoint. Verdict: sound, medium confidence.

If a provider credential is rotated, the desired document changes because it
contains the full report naming that credential generation. Its digest, a
SHA-256 fingerprint of the complete content and installed origin, therefore
changes too. There is no second editable destination or credential field to
silently disagree with the report. The plan required exact desired/applied
identity without choosing this representation. The authenticated administrator
is responsible for the truth of the report's observations; the storage and core
processes check identity, freshness and compatibility, not the truth of remote
policy statements merely because their text says `passed`. A future Cloud
issuer must produce current evidence before using this API.

### Use private HTTPS for bounded storage coordination

When: init-authority checkpoint. Verdict: sound, medium confidence.

A recorder hands a small init object to one isolated storage process. That
process requests a committed grant from the private web API and talks directly
to the provider within the remaining deadline. It does not join the Erlang
cluster or put media onto a new broker queue. The plan required isolated provider
credentials but left this transport unspecified. HTTPS gives this short exchange
an existing bounded request/response path; durable state remains in CNPG, and
late provider facts return to the same owner. This choice does not select the
GPU job transport: comparable RPC/JetStream measurements are still required for
that independently scoped work.

### Pin workload certificates in addition to trusting their issuer

When: init-authority checkpoint. Verdict: sound, medium confidence.

A certificate signed by the deployment CA proves membership in that trust
domain, but it should not let every workload act as storage. Each listener also
checks the exact configured certificate fingerprint and a separate bearer token.
The plan required workload authorization without choosing between a dedicated
SPIFFE policy and a certificate pin. A pin keeps this single-workload checkpoint
explicit and avoids adding another identity controller. Rotation requires new
mounted configuration, a rollout and a new desired revision; it does not prove
old processes or provider keys have been retired across a fleet.

### Retain installation history without turning it into permission

When: init-authority checkpoint. Verdict: sound, medium confidence.

After an applied window expires, an administrator can still see which revision
was applied, but its remaining time is zero and both readiness fields remain
unavailable. The grant owner checks the live database window again before
committing any send permission. The plan left this status representation open.
Keeping the acknowledgment helps diagnose a failed installation without erasing
history; clients must check the actual grant, never infer permission from the
presence of `applied_revision`. Applying a shorter-lived report only shortens
the existing expiry. Its original issue time already defines the thirty-second
ceiling, so another independently mutable challenge-expiry column is unnecessary.

### Bound ingress, active work and evidence callbacks separately

When: init-authority checkpoint. Verdict: sound, medium confidence.

A slow recorder can consume the upload deadline while sending its request body;
the storage process does not reset that clock when it receives the last byte.
One active task serves uploads, with a finite listener connection budget and a
1.4 MB JSON ceiling for at most one MiB of decoded init bytes. The plan required
bounded work but did not select those transport limits. A later observation or
verification callback gets its own one-second cap so an expired provider budget
does not discard already-observed facts. Those callbacks cannot authorize a
second PUT. Capacity beyond this checkpoint requires measurement and its own
admission design.

### Require explicit installation sequencing instead of background renewal

When: init-authority checkpoint. Verdict: sound, medium confidence.

If storage starts while the private control listener is unavailable, its single
five-second challenge attempt fails and it stays unavailable. It does not keep
retrying until an old configuration unexpectedly becomes active. The plan did
not specify startup orchestration. Infrastructure must install the control
listener first, then start storage and apply its fresh challenge. A new boot needs
a greater desired revision. This makes this checkpoint's behavior finite and
explicit; Cloud still needs to implement the orchestration and cannot treat a
running pod as evidence of storage readiness.

## Sound, high confidence

### Share the private listener while separating credential purposes

When: deployment-scoped media authentication pass. Verdict: sound, high confidence.

A caller that can reset an account password must not automatically gain media
access. Routes select either the account credential or a separate media credential
before parsing a body. Media can enable this same pod-only listener without
installing an account token, and equal configured tokens fail media validation.
The installed UUID and generation identify this process, never tenant routing.
One context owns configuration validation for startup and HTTP authentication;
the plug owns header cardinality and decodes paths exactly as the router does.

### Keep installation generations exact across configuration and HTTP

When: deployment-scoped media authentication pass. Verdict: sound, high confidence.

A large generation must not change when YAML or JSON passes through a numeric
parser. Generations therefore use canonical decimal strings in values,
environment variables, headers and acknowledgment, bounded to positive signed
bigint values. Chart authors must quote the value. The chart rejects generic
environment overrides of the three media installation fields, even when media is
disabled, so those overrides cannot bypass identity validation or Secret custody.

### Use arrival time for observation and revisions for ordering

When: private qualification receipt pass. Verdict: sound, high confidence.

When a newer revision arrives, the accepting application node records its UTC
clock. An exact retry keeps that original timestamp. The plan did not choose a
receipt clock; nodes can disagree, so only revisions order submissions and the
timestamp never proves freshness. Actor-label bounds and input-before-revision
validation are internal/API discretion; neither establishes caller identity.


### Bound the receipt wire contract and return only receipt metadata

When: private qualification receipt pass. Verdict: sound, high confidence.

A duplicate JSON key can disappear when a general parser converts input to a
map. The private receipt route therefore reads at most 16 KiB with a five-second
body-read timeout and uses ordered JSON objects until duplicate rejection is
complete. That size accommodates the existing bounded report and envelope; it
is a transport limit, not a retention or freshness policy. PUT replaces one
binding's current receipt and GET reloads it. Stable status codes distinguish
bad input, revision conflicts, oversized bodies and storage failure without
returning submitted reports, custody references or database details.

The plan required bounded exact input but did not choose these wire details.
The receipt's identity hashes a fixed ordered array containing the binding,
revision, state and existing report digest. This binds the complete envelope
while preserving the report module as the only owner of report canonicalization.
It deliberately does not substitute for the larger desired-configuration digest.


### Define reported observations before installing storage authority

When: qualification report pass. Verdict: sound, high confidence.

The merged Cloud plan requires a product-owned format but leaves its delivery
order open. A caller can now submit bounded observations and obtain their content
fingerprint. Even if the caller labels every check passed, this operation cannot
authorize an upload. Accepting an arbitrary caller's ready flag in the uploader
would instead create an authority source before authenticated configuration and
isolated credential custody exist. Future enforcement must match the report to
the retained binding and a fresh authenticated exchange. Issue and expiry times
remain reported data here, so reading an old report never starts a new clock.

### Reuse destination identity and fix canonical report bytes

When: qualification report pass. Verdict: sound, high confidence.

The control plane needs to distinguish a changed credential from a changed
storage destination. The report embeds the existing destination input and calls
its validator, rather than introducing another set of destination rules or
accepting a claimed destination digest. Rotating a key changes the report hash
while the destination hash remains stable. Sorted ASCII JSON keys, explicit
escaping and exact integer encoding give producers one byte contract to hash;
ordinary equivalent JSON could otherwise produce different fingerprints. The
plan required a canonical digest but left this encoding unspecified. Future
transport must reject duplicate keys and bound bytes before decoding; this
decoded-object parser cannot recover information the decoder already discarded.

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

### Recorder claims and allocated identities are distinct from ingest discovery

When: durable recorder claim pass.

A retained CNPG RecorderClaim row belongs to the unique source/profile ingest
owner. Claim operations lock ingest owner before claim, atomically manage
the recorder consumer, and recheck database time before committing. New-work
admission takes the outer fence first; [recording control](recording-control.md)
owns that order. Competing live claimants are refused. Each worker generates its token once; it never reads
back a token to resume another worker's publication rights. Reacquisition after
release or expiry increments a separate recorder epoch without restarting live
ingest. A block sequence is reserved durably before filesystem creation; failed
I/O or crashes burn allocations. File listings never allocate identities.
Each recording start also labels a fresh clock epoch; it does not assert media
clock continuity through a recording gap. UTC mapping remains explicitly unknown.

The earlier worker had only local Registry exclusion and a random consumer key.
Those could admit two trusted workers on separate nodes under one ingest epoch.
This correction follows the spec's durable ownership requirement. A publication
must check both original handles through RecorderOwnership.with_current; the
ingest fence alone does not establish recorder ownership. Short CNPG mutations
roll back on a lost claim; external writes require immutable identities and a
later fenced publication. A sealed local snapshot is still not an archive or
playback authorization.

Legacy relay adoption can extend the owner beyond the existing relay lease.
Recorder acquisition and renewal therefore cap both claim and consumer receipts
to that persisted relay expiry. Publication rereads the active relay binding and
checks its expiry against fresh database time after the callback: the owner lock
serializes writers, but cannot prevent a relay lease expiring during the work.

### Bind recording to managed ingress and provisioned storage

When: durable recorder claim pass.

The existing media_ingest_id now travels from managed Pipeline creation into
recorder attachment and admission of every access unit. The claim requires an
active persisted relay with that same ID. Discovery only locates the pipeline;
neither a PID nor distributed registration grants exclusive ownership.

The current core deployment has no durable recording-volume identity. Runtime
configuration therefore requires SERVICERADAR_CAMERA_RECORDING_STORAGE_ID, a
deployment-provisioned UUID passed through the existing core.extraEnv seam.
There is no hostname, pod, Erlang-node or unrelated-volume fallback. This UUID
must follow the actual storage across rescheduling and change when that storage
is replaced. Provisioning and verifying that mapping is a deployment prerequisite;
this code does not provision a volume or enable recording.

The claim retains its epoch and counter, not a historical block catalogue.
Frozen descriptors and their upload leases now live on the block row; see
[Historical recording block authority](block-authority.md). Archive
upload and publication, object-location history, rotation, and reclamation
still need their own durable authorization and state transitions. A new claim
cannot reuse its predecessor's token or silently adopt old local bytes.

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
the lease expires during that work. Those local bytes stay on disk and grant no
upload authority; an unfrozen tail is not recovered here. See
[Historical recording block authority](block-authority.md).

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

### Freeze historical block authority before recorder release

When: retained block authority pass. Verdict: sound, high confidence.

A recorder can finish a local file and exit before anyone uploads it. The file
now has its own retained database row, allocated with its sequence before disk
creation. While the original recorder is still authorized, it freezes the exact
init, format, clock, byte map and hashes into that row. A later upload worker
gets a separate expiring token for those bytes, even after another recorder
starts. It cannot substitute new bytes or borrow the current recorder's rights.

The plan required historical ownership but did not prescribe its resource shape.
One block row owns both immutable capture metadata and its upload lease; an
additional generic job or lease table would duplicate the same lock boundary.
The receipt-free descriptor validator is shared with the archive manifest so
their finite format limits cannot drift. Details and the remaining recovery
boundary are in [Historical recording block authority](block-authority.md).

### Leave unregistered historical tails unavailable

When: retained block authority pass. Verdict: sound, high confidence.

If the recorder seals a file and dies before the database accepts its descriptor,
the file remains on disk but cannot be uploaded through this API. A replacement
recorder must not turn a plausible old journal into new authority. Recovering
that interval requires an earlier database-authorized prefix and a safe way to
inspect storage without racing the old writer. This narrow pass deliberately
does not invent either proof, delete the tail or call it an archive. The choice
keeps later recovery work explicit and prevents a stale writer from extending
historical coverage after its lease expired.

### Measure provider operations within one bounded diagnostic

When: conditional-write and explicit-encryption diagnostic pass. Verdict: sound,
medium confidence until exercised against the provider.

The existing multipart control retains its 5 MiB part and cross-part read.
Additional completion and encryption cases use a single 64 KiB final part;
they exercise distinct commit semantics without repeating the large transfer.
The successful path uses 75 diagnostic requests and 21 cleanup requests, below
the existing 80/30 limits. Failure paths retain exact cleanup receipts and fit
the same limits or explicitly report incomplete cleanup.

Conditional acceptance requires exactly one successful writer and one
`412 PreconditionFailed`, followed by verification of the surviving bytes.
Unexpected statuses, including 409, fail closed without retries or an inferred
support claim. One competing pair per operation is bounded qualification, not a
proof over every request ordering. PUT and multipart results stay separate;
their summary cannot hide a failed or untested operation.

### Keep concurrency subordinate to the diagnostic's authority

When: provider contention pass. Verdict: sound, high confidence.

The caller reserves both requests and their complete byte ceilings before two
short-lived workers send them. Only the caller updates cleanup receipts and the
durable journal. Each transport carries its existing absolute deadline, including
time waiting to start; a second task timeout would create ambiguous ownership
without strengthening that bound. This keeps the two-writer experiment within
the same budget and recovery authority as the serial controls.

Explicit AES256 request headers are signed, and HEAD must attest encryption on
each tested object. That establishes neither a bucket policy rejecting plaintext
uploads nor safe recorder credentials. Synthetic TLS tests qualify the diagnostic
only; no provider capability or Cloud readiness follows from their passing.

### Keep destination identity canonical and immutable

When: archive-binding pass. Verdict: sound, medium confidence for endpoint syntax;
high confidence for immutable identity.

Version 1 accepts canonical HTTPS DNS origins on implicit port 443, without a
trailing slash, and bounded ASCII allocation, region and bucket tokens. It rejects
equivalent-looking URLs instead of normalizing an already registered identity.
Custom-port S3 deployments need a deliberate contract extension; syntax alone
does not establish DNS or egress safety.

One provisioning reference and generation owns exactly eleven input fields.
Product derives the local UUID and ordered-JSON SHA-256. An identical provisioning
retry succeeds; changed content at the same generation fails without rewriting
history. A new destination needs a new generation, while credential rotation
changes neither that identity nor old blocks. The synthetic golden digest owns
the serialization contract.

### Separate destination registration from storage authority

When: archive-binding pass. Verdict: sound, high confidence.

Registration can retain a destination before provider qualification exists.
Every row remains unqualified in this pass, with no activation or credential API.
Persisting identity therefore cannot enable an upload. Qualification, credential
generations and SaaS reconciliation remain separate contracts.

### Bind a retained block through its existing upload fence

When: archive-binding pass. Verdict: sound, high confidence.

A nullable restrictive foreign key binds a frozen block once under the existing
upload coordinator's token, epoch, descriptor and original deadline. Later leases
retain the destination; expiry rolls back a pending bind. Ash's atomic
changing-from-null validation also rejects replacement from a stale resource
struct. This reuses the block's row-lock owner rather than adding another lease
or table, and does not treat a local fence as cancellation of remote I/O.

### Encode recovery metadata from the retained descriptor

When: persisted-descriptor manifest pass. Verdict: sound, high confidence.

After restart, a publisher has the frozen descriptor rather than the live
packager's native initialization structure. `Manifest.encode_descriptor/2`
validates that whole descriptor before attaching storage receipts; the existing
snapshot encoder delegates to the same path. This preserves v1 bytes and object
keys without another format validator or a fabricated packaging snapshot.
Encoding still establishes neither remote byte integrity nor publication authority.

An independently calculated digest and object-key constant guard compatibility.
Negative controls also verify the actual invalid-input paths. One existing
unsupported-profile test updated the outer test context instead of its format;
correcting the operand preserves the assertion and makes it fail when the codec
guard is deliberately weakened. The new descriptor mutations use the same
correct local-root pattern. Every earlier assertion remains.


### Commit immutable intent before adding dispatch lifecycle

When: upload-intent checkpoint. Verdict: sound, medium confidence.

A future uploader first names the exact object it intends to send. This pass
stores that identity once for each frozen block and object role; a later worker
receives the same record after lease replacement. It does not create a mutable
attempt row or claim that a storage request happened. The plan required durable
publication intent but left the implementation boundary open. Splitting the
immutable identity from dispatch observations makes each boundary independently
reviewable and leaves provider operations disabled. Those contracts now live
in [upload-dispatch.md](upload-dispatch.md). Provider send remains absent.

Preparation also rejects an existing caller transaction. Otherwise a caller could
receive an intent ID, hand it to another worker, then roll back its outer
transaction. A successful return now means preparation committed; it does not
authorize the recipient to send bytes. This limits future bulk orchestration to
calls outside an ambient transaction. The choice is sound because it keeps the
durable handoff explicit, with no extra process or nested-commit fiction.

### Keep one unresolved operation beside each immutable object

When: bounded dispatch checkpoint. Verdict: sound, medium confidence.

An uploader can lose the reply to a storage request and then lose its database
lease. The replacement worker must not interpret its fresh lease as permission
to send the old operation again. This checkpoint therefore stores one operation
UUID per object intent, including its original actor, lease fingerprint and
deadline. Preparing it again returns that identity; replacing the lease cannot
rearm it. The plan required durable attempts but left this first checkpoint's
retry policy open. This deliberately conservative choice blocks automatic retry
until a later reconciliation contract can establish what happened remotely.

The marker records a committed local decision only. An unqualified destination
can retain bookkeeping for review, but no adapter is connected and nothing can
send. Future code must check current provider and credential/policy authority
before wire I/O; treating the marker as that authority would be incorrect. The
request digest describes ordered immutable logical fields rather than provider
signing bytes, so later signing must own its own exact-wire contract.

### Retain bounded first evidence instead of an unbounded response log

When: bounded dispatch checkpoint. Verdict: sound, medium confidence.

A request can time out and then return a response late. Keeping separate timeout
and response fields preserves both facts regardless of arrival order. If another
response contradicts the first, the coordinator keeps the first receipt, records
the first conflicting digest and timestamp, commits, and only then returns an
error. An exact retry after that conflict stays an error. The plan required
durability but did not choose an evidence shape. A bounded allowlist of status
and opaque provider IDs avoids retaining arbitrary bodies, headers or secrets;
an 8192-byte database bound backs the 4096-byte accepted JSON limit. Future
diagnostics can identify conflicting evidence without growing a per-retry log.
This is transport evidence, never a verified object or availability claim.

### Reuse the upload fence with a retained deadline cap

When: bounded dispatch checkpoint. Verdict: sound, high confidence.

A worker prepares an operation with two seconds remaining, then renews its upload
lease for longer. Its old operation still expires after those two seconds.
The existing upload-fence function gains a four-argument form which checks the
operation cap with database time before and after the callback, while retaining
the original upload-row check. Existing three-argument callers keep their current
lease behavior. The gap was how to apply the extra cap without changing renewal
for unrelated work. One shared fence gives rollback a single owner, and the
existing renewal/rollback assertion stays intact beside a new cap assertion.

### Measure optional codecs without widening recording admission

When: native codec capability pass. Verdict: sound, high confidence.

One finite synthetic fixture exercises the pinned parsers and CMAF muxer, then
supplies independently decoded bytes to Chromium. Production Packaging, Sink,
Descriptor and Worker stay baseline-only. An explicit HEVC rejection is a browser
capability result; an accepted stream still has to decode correctly. This keeps
library feasibility separate from an unimplemented product contract.

### Keep experimental timing budgets separate from capture accuracy

When: native codec capability pass. Verdict: sound, medium confidence.

Native decoded-marker measurement allows 50 ms around the injected offset;
browser observation allows 150 ms for callback scheduling. The browser uses its
pinned ScriptProcessor API with silent output and explicit cleanup. These choices
make a short dependency experiment observable without promising physical clock
accuracy or setting the eventual production synchronization objective. Six seconds
of fixed input establish correctness only; sustained load and adversarial-input
bounds need separate acceptance.

### Observe sender reports without promoting them to trusted UTC

When: RTCP clock capability pass. Verdict: sound, high confidence.

The existing synthetic RTSP harness sends fixed invented reports over TCP and
waits for their receipt before checking actual RTP callbacks. Independent calendar
constants provide the oracle. A fresh client starts without a mapping, while a
contradictory report is recorded as a library limitation. This isolates clock
mapping from packet loss and preserves unknown UTC in production; authentication,
report age, discontinuity and uncertainty policy remain product decisions.

### Measure grouping with synthetic GOPs and an independent decoder

When: logical block-byte pass. Verdict: sound, high confidence.

The plan left the finite input shape unspecified. One synthetic two-second GOP
(a keyframe followed by its dependent frames) is repeated with increasing media
timestamps. Production packaging makes every fragment; no container bytes or
fragment metadata are fabricated. A separate decoder must recover all 960
expected frames after each grouping is stored and recovered. Omitting an append
was observed to fail this check. Repetition keeps the existing media keeper small
and bounded, but cannot establish diverse-scene compression or capacity.

Actual spool file lengths and receipt-free encoded descriptor lengths are
reported in [block-byte-costs.md](block-byte-costs.md). They expose repeated
per-block bytes without inventing a database or uploader. Future task 0.6 work
must measure index/WAL, cache and object requests at their real owners before
turning this grouping comparison into a production size or cost decision.

### Let the remote executor own the fixture action deadline

When: fixture timeout repair. Verdict: sound, high confidence.

If a synthetic encoder hangs, the BuildBuddy executor now ends its fixture action
after 120 seconds with no extra termination grace. The earlier Bazel execution
requirement was silently filtered out, so normal passing tests could not prove
the advertised ceiling. The plan required a finite experiment but left the build
mechanism unspecified. Both existing targets now use the executor's supported
properties, without adding a wrapper, dependency or production timeout setting.
An actual stalled generator was terminated after 120.01 seconds; the temporary
delay was removed before positive checks. Future local execution cannot inherit
this RBE-only guarantee, and product media deadlines remain separate contracts.


### Ship permanent stop before positive storage authority

When: durable recording stop checkpoint. Verdict: sound, medium confidence.

An operator can already explicitly enable local recording under existing leases,
but a stored qualification report cannot grant S3 access. This pass adds a stop
that survives process restarts and rejects every later acquire, renewal, block
reservation and dispatch marker. It deliberately has no resume command. The plan
required revocation and preservation but did not choose this intermediate scope.
This lets the restrictive half be verified without inventing storage readiness.
A future enable command must supply current storage authority and fence work
from earlier generations; deleting the stop row is not a product resume path.

### Serialize stop with new work through one deployment-local row

When: durable recording stop checkpoint. Verdict: sound, medium confidence.

If a recorder requests a block while an operator stops recording, both first
lock the same database row. Whichever owns that lock first determines the order:
an earlier request retains its original lease, while a later one is denied.
The row is initialized without changing existing values, so even the first stop
has the same ordering. The plan left this coordination mechanism unspecified.
One row avoids a new process, cache and invalidation protocol, at the cost of
serializing these short admission transactions across recorders. It is never
consulted for every frame. Future capacity work must measure this contention
before raising recording concurrency. Admission and status initialize the row
with a primary-key upsert that updates no fields, then read it under lock; this
also avoids a startup gap before the first administrative command.

### Bind a small stop document to authenticated installation provenance

When: durable recording stop checkpoint. Verdict: sound, high confidence.

A replacement runtime generation can read a retained stop, but it cannot reuse
that stop's revision to claim a different origin. The next write needs a higher
revision, and an older runtime cannot overwrite it with a larger number. A digest
binds the exact accepted fields to the installed identity. The plan required
content identity and monotonic changes but left the representation unspecified.
Canonical decimal strings preserve bigint precision across JSON clients; a 1024
byte document ceiling leaves ample room for the three accepted fields. The
shared private JSON reader rejects duplicate keys before either recording or
qualification parsing can discard them. This does not add tenant routing.

### Report stop enforcement without claiming complete application or drain

When: durable recording stop checkpoint. Verdict: sound, high confidence.

After the stop commits, the caller sees `stop_enforced: true`, the received
revision and its digest. It still sees no applied configuration revision,
unavailable readiness and no drain attestation. A worker or remote request may
still be completing earlier work. The plan defined full desired/applied readiness
but did not name a partial stop status. Keeping those meanings distinct prevents
Cloud from treating a successful stop request as permission to remove storage.
Future lifecycle work must gather its own preservation and revocation evidence.

### Let the media producer end only its attached recorder

When: durable recording stop checkpoint. Verdict: sound, high confidence.

When renewal encounters stop, the worker asks the exact producer feeding its
inbox to finish that recorder stream. The producer places the end marker after
accepted media and keeps sending to live viewers. The recorder then uses its
existing packaging and sealing path within the lease it already had. The plan
required drain without interrupting live consumers but left the signal owner
unspecified. Producer ordering avoids a new queue or per-frame control query;
a failed or expired drain retains recoverable bytes instead of extending rights
or manufacturing a seal. This provides no fleet-wide completion proof.


### Preserve owner transaction errors while requiring stop to commit

When: durable recording stop checkpoint. Verdict: sound, high confidence.

A rejected block reservation must still tell its caller that ownership was lost,
not turn into an unrelated control-store failure because another transaction
surrounds it. The shared stop fence therefore preserves the existing owner's
error reasons when nested database rollback reaches it. Admission and status
retain existing transaction composition, while stop rejects an explicitly open
transaction so a success cannot later disappear in the caller's rollback. The
plan required durable stop without choosing these API semantics. Only database
connection/PostgreSQL failures become a bounded unavailable response; programming
errors remain visible. Future callers must still acquire the control lock before
ownership locks and keep preservation paths outside the stop gate.

### Reuse the release while isolating its process and mounted credentials

When: init-authority checkpoint. Verdict: sound, high confidence.

The storage pod uses the existing core-elx image, but starts only its dedicated
storage supervisor through `eval` with an empty release configuration. It gets
provider keys; the ordinary core and web processes do not. The plan required a
separate credential boundary but did not mandate a new image build. One existing
release avoids another dependency graph while explicit startup checks refuse a
distributed or already-running core process. The chart uses one replica and
`Recreate` updates; this does not establish distributed drain or high availability.

### Keep broad chart network rules from overriding storage restrictions

When: init-authority checkpoint. Verdict: sound, high confidence.

An operator may configure the chart's ordinary network policy to select every
pod. Because Kubernetes adds permissions from matching policies, that setting
would otherwise let the storage pod reach destinations outside its own narrow
policy. Enabling storage explicitly excludes it from both broad chart policies
and gives it a separate policy for recorder ingress, private control, DNS and
configured provider/proxy addresses. The plan did not specify this interaction.
Policies outside the chart remain an operator responsibility. The private web
ingress addition only renders when ordinary network isolation is enabled, so
enabling storage control alone cannot accidentally block normal web traffic.

### Keep late evidence tied to the identity that actually sent the object

When: init-authority checkpoint. Verdict: sound, high confidence.

If an upload finishes after credentials rotate, its verification still needs to
match the original authenticated sender. Each grant therefore retains a SHA-256
fingerprint of the full installed principal, including credential generation,
rather than reading the replacement authority row. The plan required preserving
late facts but did not specify these retained fields. This keeps verification
possible after revocation without restoring permission to send. A database
index also prevents one boot/request-nonce pair from being reused for a different
dispatch; a collision fails closed and leaves the first marker unchanged.

### Register immutable product identity through the existing private media listener

When: private archive-registration checkpoint. Verdict: sound, high confidence.

If Cloud loses a registration reply, it retries the same destination and receives
the same product binding ID. The request is a POST with an exact two-field
versioned envelope and a 4096-byte limit. The existing destination parser and
registration action remain the only owners of accepted fields, digest and
same-generation conflict behavior. The plan required provisioning input but did
not choose its transport or receipt. Reusing the installed media authentication
avoids a second credential or new tenant-routing mechanism. Cloud stores the
returned digest rather than copying the product serializer. Registration still
reports unavailable readiness, so a successful metadata call cannot be mistaken
for permission to upload. Future Cloud allocation must independently establish
provider ownership; no registration response constitutes bucket adoption.


### Distinguish destination conflicts from unavailable persistence

When: private archive-registration checkpoint. Verdict: sound, medium confidence.

When Cloud repeats a reference and generation with a different bucket, the
existing registration action reports a destination conflict. The HTTP adapter
returns 409 so Cloud keeps the original intent instead of retrying a replacement.
It validates input with the existing parser first, returning 400 for unsupported
metadata; other action errors return a bounded 503 without leaking database
information. The plan did not choose these HTTP statuses. First registration
and an identical retry both return 200 and the same receipt, avoiding a separate
created-versus-retried branch in Cloud. The guarded HTTP/database case must still
execute on the published head to prove the action's conflict reaches this status;
ordinary unit validation does not establish that persistence behavior.

### Detect observed local replacement without claiming physical-volume attestation

When: [spool lifetime checkpoint](spool-lifetime.md). Verdict: sound, medium confidence.

If an operator replaces the spool directory while a recorder is alive, a new
file can carry the same UUID text. The active handle also retains the root and
marker device/inode identifiers supplied by the filesystem, so that replacement
is refused at the next checked operation. After a restart, the worker opens a
new handle against its configured UUID; those filesystem identifiers are not
persisted as portable volume IDs. The plan required a provisioned storage UUID
but did not choose local verification mechanics. This detects observed
misbinding and replacement, not a privileged host copying a marker or changing
mounts during an operation. Cloud must still establish the physical volume
association and assign a new UUID on replacement. An operating-system mount
lock or volume attestation service would be a separate, substantially larger
contract. Future recovery must retain this distinction instead of treating a
matching text file as proof that all historical bytes are present.

### Use one fixed marker and preserve interrupted provisioning

When: spool lifetime checkpoint. Verdict: sound, high confidence.

An installer calls `Storage.initialize/2` on an empty private root. The marker
is exactly the lowercase UUID followed by a newline in `.storage-id`, rather
than a new JSON resource. Exclusive creation prevents overwriting a competing
initializer; file and directory sync establish the same local POSIX durability
boundary as the spool. An interrupted write leaves evidence for reconciliation.
A recorder cannot fix that evidence by creating a new identity. An exact
initializer retry verifies and syncs without rewriting, even when blocks now
exist. The plan left the file format and retry entry point unspecified. A
release-callable function serves explicit infrastructure provisioning without
adding a second startup mode or automatic adoption path. Cloud's future volume
workflow must invoke it before enabling recording and preserve failures instead
of silently generating a replacement UUID.

### Verify at authority, byte-mutation and receipt boundaries

When: spool lifetime checkpoint. Verdict: sound, high confidence.

When storage disappears after startup, the next append, seal or recovery
truncation checks the retained identity before touching bytes and again before
returning a new receipt. The worker checks before lease acquisition, block
reservation, attachment and renewal; progress and stopped receipts cannot expose
changed storage. An already-returned snapshot also refuses subsequent reads of
a changed root. The plan required verification but did not specify these call
boundaries. Packaging may buffer many encoded samples without a disk write, so
it retains in-memory limits without reopening the marker for every sample.
A detected change after I/O can leave bytes on disk but grants no new receipt;
it does not undo writes or delete evidence. Future playback can reuse the same
local-handle rule, while portable descriptors and manifest bytes remain free of
paths, device/inode identifiers and this local filesystem handle.
