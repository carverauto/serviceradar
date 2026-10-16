## ADDED Requirements

### Requirement: Persistent Device Bitmap Identity
The system SHALL reuse persisted device fleet ordinals for topology membership and SHALL bind native sets to a durable dictionary epoch and device entity kind.

#### Scenario: Layout and process changes preserve identity
- **GIVEN** a canonical device has an allocated ordinal
- **WHEN** a tile changes, ELK rebuilds or an index process restarts
- **THEN** the device SHALL retain its ordinal independently of row position
- **AND** canonical endpoints SHALL share the device dictionary
- **AND** aggregate glyphs and relation clips SHALL NOT allocate device ordinals

#### Scenario: Migration and lifecycle safety
- **WHEN** storage is widened to the checked `1..4294967295` range
- **THEN** existing assignments, uniqueness and tombstones SHALL be preserved
- **AND** repeat allocation SHALL NOT consume new sequence values
- **AND** merge/delete/restore and retention cleanup SHALL preserve identity without reviving a merged-away member
- **AND** rollback SHALL retain the widened storage and existing assignments
- **AND** exhaustion SHALL reject new allocations while preserving readable accepted state

#### Scenario: Unsupported identity domain
- **WHEN** a query supplies an incompatible dictionary epoch or an unsupported entity kind
- **THEN** it SHALL fail explicitly before set algebra
- **AND** interface queries SHALL remain unsupported until their identity and parent-authorization contract is separately approved

### Requirement: Bounded Incremental Topology Bitmap Index
The system SHALL maintain rebuildable native attribute indexes through bounded current-state reads, coalesced invalidation hints, rolling reconciliation and atomic published revisions.

#### Scenario: Lost hints and late commits
- **GIVEN** an update commits after a scan passes its identity or its notification is lost
- **WHEN** a subsequent bounded reconciliation reaches that identity
- **THEN** current canonical state SHALL converge idempotently on every replica
- **AND** freshness metadata SHALL distinguish a completed reconciliation from pending or incomplete work
- **AND** existing identity revisions or timestamps SHALL NOT be treated as a proven global commit-order cursor

#### Scenario: Independent writers and replicas
- **WHEN** independent inventory transactions update different devices or an index replica is offline
- **THEN** bitmap freshness machinery SHALL NOT add shared bucket locks to those transactions
- **AND** each replica SHALL reconcile without consuming another replica's hints or waiting for it
- **AND** startup SHALL seed before reporting readiness

#### Scenario: Dirty work and source budgets
- **WHEN** pending changes, facet cardinality, native memory or query concurrency reach a configured limit
- **THEN** retained work SHALL remain bounded and expose staleness, unavailability or structured rejection
- **AND** publisher read batches SHALL be limited independently of pending-set capacity
- **AND** coalesced ordinal dirty sets SHALL use Roaring with an explicit byte cap
- **AND** readers SHALL NOT observe a partially published revision or partial facets labeled exact
- **AND** unavailable causal evidence SHALL NOT be synthesized from availability

### Requirement: Authorized Bitmap Query and Exact Facets
The system SHALL evaluate bounded AND, OR and ANDNOT expressions over supported sets, intersect current effective visibility and pin one coherent native revision per response.

#### Scenario: Exact query and facets
- **WHEN** a supported expression is evaluated
- **THEN** negation SHALL be relative to the authorized live universe
- **AND** each facet count SHALL equal cardinality of the result intersected with that facet value, including same-facet predicates
- **AND** empty results SHALL succeed with zero counts
- **AND** predicates without an approved canonical source SHALL return explicit unsupported errors

#### Scenario: Expression limits agree across the builder and query engine
- **WHEN** an operator groups predicates or adds EXCEPT wrappers
- **THEN** admission SHALL enforce at most 32 predicates, 65 expression nodes and eight levels with the root at level one
- **AND** every EXCEPT wrapper SHALL consume a node and a level
- **AND** over-budget expressions SHALL fail explicitly without increasing native limits

#### Scenario: Revocation during work
- **GIVEN** authority changes while a query, detail, search or overlay is in flight
- **WHEN** the response is ready
- **THEN** current authority SHALL be revalidated before bytes, counts or a 304 are delivered
- **AND** revoked work SHALL be cancelled and client membership cleared
- **AND** no tenancy or authorization bypass mode SHALL be introduced

#### Scenario: Live pagination reaches another pod
- **GIVEN** a cursor binds dictionary epoch, device kind, normalized query, authority and last ordinal
- **WHEN** the next page reaches any healthy replica
- **THEN** it SHALL evaluate ordinal greater than the cursor against that replica's current published membership
- **AND** the response SHALL report its source/index freshness
- **AND** membership may change between pages without retaining or routing to an old query owner
- **AND** a changed query, dictionary or authority SHALL require a fresh cursor
- **AND** the native result SHALL be released at request completion

### Requirement: Bitmap Filters Preserve Bounded Tile Geometry
The system SHALL apply membership to the persistent tiled world without changing layout, inventing edges or enumerating whole-fleet browser objects.

#### Scenario: Large aggregate projection
- **WHEN** a query matches members of an admitted aggregate
- **THEN** native projection SHALL return exact authorized match counts and bounded row masks
- **AND** complete aggregate membership SHALL NOT be enumerated in BEAM or the browser solely to count it
- **AND** detail pages SHALL stay within existing candidate and output limits
- **AND** unsupported filtered details or boundary populations SHALL fail explicitly rather than broaden the result

#### Scenario: Receipt or filter changes
- **WHEN** query, authority, layout or admitted tile receipts change
- **THEN** the client SHALL require a matching full overlay before rendering filtered success
- **AND** valid geometry SHALL survive membership resets
- **AND** health or membership updates SHALL NOT trigger ELK relayout

#### Scenario: Offscreen prefetch leaves the displayed result stable
- **GIVEN** an accepted overlay matches all displayed receipts
- **WHEN** an offscreen tile enters or leaves the retained geometry cache
- **THEN** the membership watch SHALL keep the unchanged displayed receipt set
- **AND** the accepted result SHALL remain visible until that set, query or authority changes

#### Scenario: Partial aggregate telemetry
- **GIVEN** a filter selects only part of an aggregate's represented population
- **WHEN** an incident edge's telemetry still summarizes its complete bundle
- **THEN** the client SHALL hide that relation and suppress its traffic rates and animation
- **AND** the whole-bundle rate SHALL NOT be shown as a filtered-population rate

### Requirement: Operator Map Set Filters
The system SHALL expose a usable map filter builder for supported canonical attributes, inventory VLAN assignments, configured device tags and named Prefix Tags, with AND, OR, EXCEPT, literal text prefixes and typed IP/CIDR predicates.

#### Scenario: VLAN set algebra on the map
- **WHEN** an operator selects `(VLAN 20 OR VLAN 30) AND unavailable EXCEPT maintenance=true` using configured inventory fields
- **THEN** the map SHALL apply that expression to device membership and exact aggregate match counts
- **AND** positions SHALL remain fixed
- **AND** the controls SHALL expose supported fields and their readiness without downloading fleet values
- **AND** unsupported predicates SHALL be reported explicitly

#### Scenario: Configured tag prefixes
- **WHEN** an operator selects a literal prefix over tag names or an indexed scalar value
- **THEN** the result SHALL union the complete matching supported postings under the query limits
- **AND** tag-name matching SHALL cover configured keys and SHALL NOT imply arbitrary JSON-path indexing
- **AND** exceeding the expansion or memory budget SHALL fail explicitly instead of returning partial matches

#### Scenario: Any known address falls within a network
- **GIVEN** a device has primary and interface addresses, including IPv4 and IPv6
- **WHEN** an operator selects a valid CIDR
- **THEN** the device SHALL match if any current canonical device/interface address belongs to that network
- **AND** multiple matching addresses SHALL count the device only once
- **AND** bits from different addresses SHALL NOT create a false match
- **AND** invalid CIDRs or incomplete address sources SHALL fail explicitly

#### Scenario: Clearing the query
- **WHEN** the operator clears all active filtering
- **THEN** the client SHALL cancel membership work and restore the unfiltered base view including boundary links
- **AND** an unfiltered view SHALL NOT wait for query-index readiness
- **AND** a deliberately selected all-devices expression SHALL still follow query membership guards

#### Scenario: Named Prefix Tag groups
- **GIVEN** a locally available Prefix Tag source assigns a label to configured networks
- **WHEN** the operator selects that source and label alongside VLAN or other Boolean filters
- **THEN** devices with any current address matching that label under the existing full prefix-chain semantics SHALL participate in the set expression
- **AND** shared addresses or overlapping prefixes SHALL NOT count a device more than once
- **AND** the response SHALL use one captured prefix version and report its freshness
- **AND** subsequent device pages SHALL use current label membership without routing to a frozen owner
- **AND** missing sources, catalog exhaustion or range-budget overflow SHALL fail explicitly without partial results
- **AND** discovery SHALL be paged and query evaluation SHALL NOT scan the fleet in BEAM or call core by RPC

### Requirement: Typed Binary Tile Overlay
The system SHALL replace the active tiled path's per-tile JSON membership overlay with a versioned binary full replacement containing typed masks, states and counts aligned to admitted Arrow rows.

#### Scenario: Existing health and flow overlay transport
- **WHEN** the binary overlay path is enabled
- **THEN** existing per-tile bulk health and flow JSON SHALL be replaced with typed binary fields
- **AND** directional rates, coverage, eligibility, unknown values and observation timestamps SHALL preserve their current semantics
- **AND** size checks SHALL measure the binary representation without a JSON round trip
- **AND** each tile response SHALL remain within 256 KiB under the existing bounded fetch scheduler
- **AND** bulk JSON SHALL NOT be embedded inside a binary envelope

#### Scenario: Dense telemetry remains within retention limits
- **WHEN** the complete displayed telemetry would exceed the 5 MiB retention cap
- **THEN** the client SHALL admit a deterministic subset before fetching, including maximum row bytes and CPU/GPU metadata allowances
- **AND** omitted telemetry SHALL remain explicitly unknown without repeated fetch/eviction churn for an unchanged admitted view

#### Scenario: Bounded typed columns
- **WHEN** an overlay is produced for at most 64 admitted tiles of 128 glyphs each
- **THEN** it SHALL bind exact tile receipts and row counts, dictionary, query and authority
- **AND** it SHALL contain matching u8, causal u8, availability u8 and little-endian matched-count u32 columns
- **AND** every row in the response SHALL use the same pinned query revision
- **AND** the envelope SHALL carry the exact whole-query count rather than summing overlapping visible tiles
- **AND** causal and availability domains SHALL remain explicit and separate
- **AND** bulk overlay data SHALL NOT use JSON arrays, base64 or a browser Roaring/WASM runtime

#### Scenario: Full replacement and invalid input
- **WHEN** a complete valid replacement arrives
- **THEN** the browser SHALL publish its columns atomically
- **AND** a skipped intermediate replacement SHALL NOT corrupt the next frame
- **AND** obsolete sequences, mismatched receipts or authority, invalid enums and malformed lengths SHALL be rejected before excessive allocation or partial mutation
- **AND** no XOR history or chunked baseline assembly SHALL be required
- **AND** each matched count SHALL be bounded by its geometry row population, with unsupported boundary counts zero
- **AND** decoding SHALL preserve leading U+FEFF identifier content in both membership and telemetry receipts

#### Scenario: Repeated invalid frames cannot bypass retry backoff
- **WHEN** watch binding succeeds but replacement frames remain invalid or reset
- **THEN** retries SHALL back off through 1, 2, 4, 8 and at most 10 seconds
- **AND** a successful binding alone SHALL NOT reset the attempt counter
- **AND** an accepted complete frame or a genuinely changed query/view SHALL begin a fresh retry epoch

#### Scenario: Slow viewer and resource lifetime
- **WHEN** a viewer falls behind, reconnects, evicts tiles or disables the feature
- **THEN** obsolete work SHALL be coalesced or reset under fixed pending-frame limits
- **AND** a fresh matching replacement SHALL be required after reconnect
- **AND** retained membership and staging SHALL fit the 8 MiB budget, with each frame at most 256 KiB
- **AND** eviction, disconnect and disable SHALL release obsolete membership resources

### Requirement: Measured Bitmap Scale and Copy Budget
The system SHALL validate the index with independently synthetic benchmarks and report latency, memory, copies, concurrency, freshness and limitations.

#### Scenario: Primary scale acceptance
- **GIVEN** 100,000 infrastructure and 1,000,000 endpoint devices with declared compact and sparse ordinal distributions
- **WHEN** representative uncached queries run after declared warmup
- **THEN** four-term filter p95 SHALL be below 5 ms and query plus fifty exact facets p95 below 50 ms
- **AND** steady index-owned memory per replica SHALL be below 200,000,000 bytes including projections and retained revisions
- **AND** one-percent full-population churn SHALL report admitted-overlay payload bytes, convergence and database reconciliation load
- **AND** every admitted overlay SHALL fit 256 KiB independent of ordinal sparsity
- **AND** array-baseline, peak replacement and end-to-end authorization results SHALL be reported separately

#### Scenario: Sustained operation
- **WHEN** 100 concurrent views, slow viewers, two replicas, missed hints, restarts and authority changes are exercised
- **THEN** pending work, convergence and retained native/browser resources SHALL stay within declared bounds
- **AND** Arrow attributes SHALL remain typed binary columns with copies measured at each boundary
- **AND** GPU buffers SHALL remain alive while queued commands reference them
- **AND** software-GPU results SHALL NOT be presented as actual-hardware performance or end-to-end zero-copy proof
