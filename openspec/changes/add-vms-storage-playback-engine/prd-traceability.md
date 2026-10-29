# PRD disposition and original proposal comparison

Source: [issue #4913 PRD comment](https://github.com/carverauto/serviceradar/issues/4913#issuecomment-6357595299).
P0-P3 refer to the stages in [proposal.md](proposal.md). Deferred means a planned
capability with an implementation gate, not an omitted requirement.

## Existing scope retained

| Earlier proposal | Retained contract | New owner |
| --- | --- | --- |
| add-camera-recording-storage / #4913 | One ingest; independent recording leases; fencing; bounded keyframes; clock quality; integrity; manifests; idempotent recovery; credential/store boundaries | This proposal, camera-recording and camera-streaming deltas |
| add-recording-playback-lifecycle / #4915 | Authorized time-bounded replay/exports; gaps; short-lived handles; hold/delete/export races; verified deletion; dashboard cleanup and spatial links | This proposal, camera-recording delta |
| add-edge-recording-archive / #4914 | Disconnected admission, bounded filesystem storage, optional S3 archive receipts, catch-up and reclamation without central index availability | Existing separate proposal; dependency reference updated |
| add-shared-spatial-resources and add-spatial-observation-ingestion | Resource identity, placement, observations | Existing owners; no duplicate camera/location registry |

The two consolidated proposals are not archived as implemented. Their original
text remains in Git history. This supersession changes planning ownership only.

## Every PRD functional requirement

| PRD ID | Disposition | Contract / acceptance |
| --- | --- | --- |
| FR-1.1 | P1 | Shared ingest fanout; independent leases and failure isolation |
| FR-1.2 | P0/P1 H.264; P2 HEVC | CMAF sink/format proof; target fragment duration constrained by GOP |
| FR-1.3 | P1 | Bounded append file, duration and bytes; disk-backed recovery |
| FR-1.4 | P1 | Versioned fragment map with media/UTC time and unknown motion state |
| FR-1.5 | P1 | Immutable block upload, checksum, manifest and idempotent publication |
| FR-1.6 | P2 | Byte-budgeted cache; 24-hour residency is a capacity objective |
| FR-1.7 | P1 | Provisional open block and complete-fragment local reads; archive status separate |
| FR-1.8 | P2 | Measured G.711-to-Opus/AAC capability; bounded isolated audio processing |
| FR-1.9 | P0/P1 | RTCP/UTC mapping with uncertainty; receive time is not exact capture time |
| FR-2.1 | P0/P1 | Ash block schema; prototype Timescale/index layout; remove tenant column |
| FR-2.2 | P2 | Measure compression and update/hold interactions; no >90% promise |
| FR-2.3 | P2 | Bounded coverage/motion aggregates with freshness and invalidation |
| FR-2.4 | Adapted | Dedicated runtime DB/schema; SaaS control-plane isolation and resource authorization |
| FR-3.1 | P1 | Authorized dynamic HLS with init maps and byte ranges; prevent whole-object leakage |
| FR-3.2 | P1 | Explicit wall-clock gap API plus tested HLS discontinuity/player behavior |
| FR-3.3 | P2 | Optional ephemeral synchronized replay; clock tolerance, TURN and worker budgets |
| FR-3.4 | P2 | Actual codec configuration/capability negotiation; admission-controlled viewer fallback |
| FR-4.1 | P3 | Bounded sampling worker tap with independently admitted decode/inference |
| FR-4.2 | P3 | Sprite derivatives with authorized references and retention |
| FR-4.3 | P3 | CLIP visual retrieval proposal; model/version/dimensions and projection sizing |
| FR-4.4 | P3, spatial owner | Existing resource placement plus separately specified field-of-view queries |
| FR-4.5 | P3 | OCR/POS event/search contract; evaluate pg_textsearch instead of assuming it installed |
| FR-5.1 | P2, revised | Hold-aware deletion and metadata cleanup; no unsafe independent drop_chunks/expiry |
| FR-5.2 | P2, revised | Durable verified evidence copies before hold acceptance; whole blocks initially |
| FR-5.3 | P2 | Bounded standard MP4 export with keyframe and derivative provenance rules |
| FR-5.4 | P1/cloud | Private purpose-scoped buckets; retention-class keys without tenant routing; restricted CORS |
| FR-6.1 | P3, edge owner | Separate high-quality edge recording and cloud substream policies |
| FR-6.2 | P3, edge owner | Authorized on-demand edge fetch; explicit disconnected/unavailable state |

## Session additions

| Addition | Disposition |
| --- | --- |
| ServiceRadar Cloud provisioning/security | Cloud contract C1-C4 and separate control-plane issues |
| Existing test deployment, RTSP source and GPU nodes | Private operational target; synthetic CI first, no captured fixtures |
| linode-cli test bucket provisioning | Future operational acceptance; isolated private test resources and verified cleanup |
| NATS versus Elixir messaging | JetStream for durable jobs, RPC/PubSub for ephemeral control; benchmark performance |
| Whisper and transcript NLP search | P3 text + optional pgvector embeddings, timestamp links and authorized retrieval |
| stream-doctor | P0 experimental A/V-drift CI evaluation, with its current protocol limitations |
| Smelter composition | Optional derivative worker; measured cost and hardware support |
| Logo, location and camera labels | Player overlays by default; opt-in burned-in derivatives with capture-time labels |

## Targets requiring evidence

Zero video transcoding means no video decode/re-encode on supported ingestion,
not zero CPU. Object-count reduction differs from API request/cost reduction.
Block completions differ from total database writes. Timeline query latency
differs from browser first-frame latency. Compression, 10,000-camera scale,
24-hour cache, synchronized replay accuracy and the PRD's schedule remain
unproven until their P0/P2 experiments pass.
