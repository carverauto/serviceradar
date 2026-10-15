## ADDED Requirements

### Requirement: Persistent Typed Bitmap Identity
The system SHALL reuse persisted device fleet ordinals for topology query membership and SHALL namespace every bitmap by dictionary epoch and entity kind.

#### Scenario: Layout and process changes preserve identity
- **GIVEN** a canonical device has an allocated ordinal
- **WHEN** a tile changes, ELK rebuilds, or an index process restarts
- **THEN** the device SHALL retain its ordinal independently of row position
- **AND** canonical endpoint devices SHALL share the same device dictionary
- **AND** aggregate glyphs and relation clips SHALL NOT allocate device ordinals

#### Scenario: Safe migration and identity transitions
- **WHEN** signed integer storage is widened to the checked `1..4294967295` range
- **THEN** all existing IDs, uniqueness and tombstones SHALL be preserved
- **AND** IDs SHALL never be reused or renumbered to close gaps
- **AND** merge/delete/restore processing SHALL converge on the current canonical identity without reviving a merged-away member
- **AND** capacity exhaustion SHALL reject new allocations explicitly while retaining readable accepted state

#### Scenario: Cross-kind or cross-epoch intersection
- **WHEN** operands have different dictionary epochs or entity kinds
- **THEN** direct set algebra SHALL be rejected
- **AND** interface-to-device projection SHALL use the current canonical parent mapping and authorization

### Requirement: Bounded Incremental Topology Bitmap Index
The system SHALL maintain rebuildable native attribute indexes through bounded current-state reads, durable dirty work, reconciliation and atomic published revisions.

#### Scenario: Lost notifications and publisher crash
- **GIVEN** a canonical write commits without a delivered notification or a publisher crashes before acknowledging work
- **WHEN** dirty work is retried or reconciled
- **THEN** current canonical data SHALL be reread and applied idempotently
- **AND** newer or late-committing changes SHALL remain discoverable
- **AND** readers SHALL NOT observe a partially updated revision

#### Scenario: Overload or incomplete source
- **WHEN** dirty work, facet cardinality, native memory, reader retention or query admission exceeds its configured limit
- **THEN** the system SHALL bound retained work and expose backlog, staleness or a structured rejection
- **AND** it SHALL NOT silently drop membership changes or label partial counts exact
- **AND** unavailable causal evidence SHALL NOT be synthesized from availability

### Requirement: Authorized Bitmap Query and Exact Facets
The system SHALL evaluate bounded AND, OR and ANDNOT expressions over supported facet sets and intersect current effective visibility before returning any result, count or membership.

#### Scenario: Exact query and facet semantics
- **WHEN** a supported expression is evaluated against a pinned revision
- **THEN** negation SHALL be relative to the authorized live universe
- **AND** facet counts SHALL equal `cardinality(result AND facet_value)` including same-facet predicates
- **AND** unsupported mappings or incomplete search sets SHALL return an explicit error
- **AND** empty results SHALL return successful zero counts

#### Scenario: Revocation after a cache hit
- **GIVEN** authorization changes while a cached query or stream update is in flight
- **WHEN** the response is ready for delivery
- **THEN** current authority SHALL be revalidated before bytes, counts or a 304 are sent
- **AND** revoked work SHALL be cancelled and client membership cleared
- **AND** tenant routing or authorization bypass modes SHALL NOT be introduced

#### Scenario: Cache and pagination revision safety
- **WHEN** inventory, negated predicates, live universe, search or authority changes
- **THEN** affected cache entries SHALL be patched from changed IDs or invalidated
- **AND** cache reuse SHALL prove unchanged dependencies
- **AND** a page cursor SHALL bind query, epochs, revision, authority, entity kind and last ordinal
- **AND** expired revisions SHALL require restart rather than mixed pages

### Requirement: Bitmap Filters Preserve Bounded Tile Geometry
The system SHALL apply query membership to the persistent tiled world without changing layout, inventing graph edges or expanding the full result into browser objects.

#### Scenario: Filtering a large aggregate
- **WHEN** a query matches members of an admitted aggregate
- **THEN** the server SHALL return authorized matching counts and bounded leaf/detail pages
- **AND** the browser SHALL NOT receive the aggregate's complete underlying membership solely to count it
- **AND** existing tile, fetch, cache and detail budgets SHALL remain enforced

#### Scenario: Tile replacement and bitmap resynchronization
- **WHEN** admitted tile receipts, query, authority or layout generation changes
- **THEN** membership SHALL require a matching baseline before being rendered as filtered
- **AND** a bitmap sequence reset SHALL preserve still-valid geometry
- **AND** health or membership changes SHALL NOT trigger ELK relayout

### Requirement: Versioned Portable Roaring Membership Stream
The system SHALL transmit actual portable 32-bit Roaring bytes for admitted-view membership using a negotiated binary envelope and atomic baseline or XOR updates.

#### Scenario: Compatible decoding and explicit state domains
- **WHEN** a Rust-produced frame is decoded with roaring-wasm
- **THEN** membership SHALL match for empty, sparse, dense, run-container and unsigned high-ID cases
- **AND** protocol version, epochs, entity kind, query, authority, view receipt and revisions SHALL be validated
- **AND** causal and availability state domains SHALL be explicit and independent of legacy enum ordering
- **AND** bulk membership SHALL NOT use JSON arrays or base64 encoding

#### Scenario: Duplicate, gap or malformed frame
- **WHEN** a duplicate, missing sequence, wrong epoch or invalid length is received
- **THEN** a duplicate SHALL NOT reapply XOR
- **AND** a gap or incompatible base SHALL request a fresh baseline
- **AND** malformed frames SHALL fail before excessive allocation or partial mutation
- **AND** late frames for an evicted view SHALL be discarded

#### Scenario: Slow viewer or partial baseline
- **WHEN** queued frames or baseline assembly reaches its declared byte, count or time limit
- **THEN** the sender SHALL coalesce or require a bounded resynchronization
- **AND** partial baselines SHALL NOT replace accepted membership
- **AND** decoded membership, WASM storage and staging SHALL fit the 8 MiB browser membership budget

### Requirement: Measured Bitmap Scale and Copy Budget
The system SHALL validate the query index with independently synthetic scale benchmarks and SHALL report measured memory, copies, concurrency and limitations alongside latency and payload results.

#### Scenario: Primary scale acceptance
- **GIVEN** 100,000 infrastructure and 1,000,000 endpoint devices with declared facet distributions and compact plus sparse ordinal variants
- **WHEN** uncached representative work is benchmarked after declared warmup
- **THEN** four-term filter p95 SHALL be below 5 ms and fifty exact facet counts p95 below 50 ms
- **AND** full-population one-percent state-churn delta p95 SHALL be below 50,000 bytes including all changed sets and envelope
- **AND** steady-state index-owned memory SHALL be below 200,000,000 bytes including dictionaries, caches and retained revisions
- **AND** the current array baseline, peak rebuild memory and end-to-end authorization latency SHALL be reported separately

#### Scenario: Sustained operation and browser lifecycle
- **WHEN** churn, concurrent viewers, slow consumers, restarts, zoom and tile eviction are exercised
- **THEN** backlog, convergence and native/browser resource retention SHALL remain within declared caps
- **AND** Arrow attributes SHALL remain binary typed columns with copies measured at each boundary
- **AND** the GPU lifecycle SHALL prevent destruction of buffers still used by queued work
- **AND** software-GPU functional results SHALL NOT be presented as actual-hardware frame-rate proof or an end-to-end zero-copy guarantee
