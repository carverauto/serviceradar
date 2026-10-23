# GPU workers, media plugins and searchable derivatives

## Execution boundary

Keep archive remuxing and normal live passthrough independent of GPU capacity.
Use optional workers for sampled decoding/inference, speech transcription,
thumbnails, viewer-specific codec fallback, composition and annotated exports.
A GPU outage delays or rejects those capabilities while recording continues.

Prefer durable JetStream pull consumers for asynchronous work because work must
survive worker loss and be consumable by Elixir or other worker runtimes. Use
Elixir RPC/PubSub for ephemeral session control, local process discovery and UI
notifications inside an existing deployment. RPC/PubSub is not a durable queue.
Do not assert that either transport is faster or cheaper without a representative
benchmark. Measure serialization, persistence, network copies and end-to-end
work latency; media computation may dominate transport.

Job admission persists a job/outbox intent before publication. Envelopes contain
version, job/attempt identity, source/block/interval, object version/digest,
operation/model/config version, budget, deadline and output reference. They carry
bounded metadata, not video or permanent credentials. Resolve narrowly scoped
short-lived media capabilities at execution time so queue delay does not force
long-lived signed URLs. Validate source ownership and allowed object ranges.

Set finite stream bytes/age, batch size, pending acknowledgements, attempts and
per-job runtime. Workers renew progress within the deadline, publish verified
output and a durable completion/result event, then acknowledge. Result/index
processing is idempotent by job/version; stale attempts cannot replace a newer
result. A crash after output or completion publication before ACK must not create
duplicate user-visible results. MaxDeliver exhaustion is explicitly reconciled
to terminal/quarantined state; it is not assumed to create an automatic dead-letter
queue. Cancellation and expired jobs release resources and account for temporary
outputs. Interactive work has reserved capacity apart from bulk jobs.

GPU workers receive separate service identities, constrained NATS subjects,
bounded read capabilities and output-only media permissions. They cannot list
other environments, delete originals, change holds or write CNPG/StarRocks.
Observations/results flow through JetStream and the owned consumer. For
transient viewer streams, use the existing authorized media/session transport;
do not enqueue every compressed frame as a durable job.

## Candidate evaluation (upstream reviewed 2026-10-23)

| Candidate | Proposed use | Gate / cost |
| --- | --- | --- |
| [membrane_mp4_plugin](https://github.com/membraneframework/membrane_mp4_plugin) | Core CMAF/fMP4 packaging, parsing and remux/export | Needed to package encoded access units, not an AI feature. Validate custom sink initialization/segment contract, seek and reconnect; no decode required for compatible remux |
| [stream-doctor](https://github.com/membraneframework/stream-doctor) | Experimental CI A/V-drift probe | Upstream labels it an early proof of concept: RTMP-to-HLS with one drift metric. Evaluate adapter and pinned daemon/SDK on RBE; do not claim RTSP/WebRTC, chaos or general playback coverage |
| [membrane_whisper_plugin](https://github.com/membraneframework/membrane_whisper_plugin) | Opt-in audio transcription worker | Produces speech transcripts; verify timestamp granularity, chunk overlap, languages, model/runtime and ARM64/GPU backend. Do not infer acceleration from the plugin name |
| [membrane_smelter_plugin](https://github.com/membraneframework/membrane_smelter_plugin) | Optional multi-camera composition, layouts and derived exports | Multiple inputs become a new rendered output. Benchmark decode/render/encode, memory and latency. Package native dependencies reproducibly; do not copy runtime binary-download setup |
| [membrane_ffmpeg_video_filter_plugin](https://github.com/membraneframework/membrane_ffmpeg_video_filter_plugin) | Optional burned-in text such as camera/location/time | Upstream currently implements TextOverlay on raw video. Decode/filter/encode is extra work; an image/logo overlay is not established support |

Pin dependency/artifact versions and digests during P0. Use Bazel targets and
approved dependency-fetching paths; runtime external artifact downloads use
ServiceRadar.HTTP.EgressClient. Validate native libraries, licensing and backend
compatibility before any release claim. This proposal installs no dependencies.

## Labels and branding

Player overlays show configured location, camera name/identifier and timestamps,
with optional ServiceRadar branding. They do not modify video bytes and can be
used for normal live/playback viewing without a server encode job. Authorize
metadata with the media; escape text and bound lengths. Never interpolate an
operator label into a shell command or raw filter expression.

Historical playback resolves versioned metadata valid at capture time; optionally
show the current label separately. An invented example is "Gate C2 / Camera 07".
Missing historical metadata is labelled unknown; current labels must not silently
rewrite the historical record. Timestamp overlays show clock quality/timezone.

Burned-in overlays are explicit derivative jobs for exports or selected
presentation streams. Persist original block/digest, interval, label revision,
render settings and derivative checksum. Watermarking is neither proof of
authenticity nor access control. Preserve immutable originals; do not encode every
24/7 camera merely to brand the viewer.

Compare passthrough/player overlay against text burn-in, image branding and
Smelter composition at representative resolutions, frame rates, stream counts
and GPU/CPU backends. Record encode quality, added latency, throughput, power or
GPU-time proxy, memory and unit cost. Reject work beyond measured budgets;
no silent expensive CPU fallback.

## Transcript and semantic search contract (P3)

Store timestamped transcript text as text with source/block/audio interval,
language, model/version, provenance and processing state. Optional embeddings
represent transcript chunks, not the canonical transcript. PostgreSQL text
search covers exact names/phrases; pgvector can add semantic retrieval using a
separate compatible text embedding model. Whisper is transcription, not itself
the text embedding index. Select dimensions/index from the model rather than
copying the PRD's CLIP dimension into every table.

Search must authorize cameras/intervals before returning snippets, vectors or
thumbnails, then link to the corresponding recorded interval. Bound chunk size,
overlap, backfill concurrency and index growth. Silence, noise, uncertain
transcription and partial results are explicit; do not present a transcript as
verified speech. Audio/transcription are opt-in capabilities.

VMS-owned transcript/search projections can live in CNPG with Ash resources.
Worker outputs first traverse JetStream; the dedicated projection consumer owns
idempotent updates. Raw historical detection/health observations still use
EventWriter and the configured telemetry backend. The later P3 proposal must
define projection versus telemetry ownership, retention and rebuild semantics
before adding a raw `vms_ai_events` firehose to CNPG. CLIP visual search,
PostGIS field-of-view and OCR/POS search retain their PRD goals but require their
own model, event and spatial contracts.

Deleting media or expiring a policy reconciles transcripts, embeddings, thumbnails
and exports according to their explicit retention/hold policy. Holds include
required derivative evidence; re-embedding tracks model versions and cannot
revive deleted or unauthorized content. No raw camera footage/audio is copied
into committed tests or model evaluation datasets.

## CI and deployment proof

Synthetic media generators provide known video markers, spoken text and
timestamps. Failure tests inject audio drift, missing keyframes, reconnect,
duplicate delivery, worker crash, expired credentials, full queues and missing
GPU support, with explicit assertions that can fail. stream-doctor supplements
browser/range/integrity tests; it does not replace them.

The designated test cluster includes an available NVIDIA GPU pool, including the
DGX Spark hardware class. Verify actual architecture, driver/CUDA and inference,
decode/encode/composition support at deployment time. Do not assume MIG, NVENC,
zero-copy or a particular model runtime is available. Ship appropriate ARM64 and
AMD64 artifacts as applicable; keep hardware-specific native code outside the
core BEAM failure domain.

A synthetic cluster test precedes the configured live RTSP acceptance pass.
Assert that worker exhaustion, restart or node loss leaves recording and
ordinary live sessions healthy. Only measured capability classes are schedulable.

## Primary references

- [NATS pull consumers](https://docs.nats.io/learn/jetstream/pull-consumers)
  and [consumer configuration](https://github.com/nats-io/nats.docs/blob/master/nats-concepts/jetstream/consumers.md):
  durable delivery still requires bounded acknowledgements and idempotent effects.
- [CMAF muxer](https://membrane-mp4-plugin.hexdocs.pm/Membrane.MP4.Muxer.CMAF.html)
  and [HLS format](https://datatracker.ietf.org/doc/html/rfc8216):
  validate actual media/player behavior rather than relying on filenames.
