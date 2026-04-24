# topology-god-view Specification

## Purpose
TBD - created by archiving change add-god-view-topology-platform. Update Purpose after archive.
## Requirements
### Requirement: Versioned Binary Topology Snapshots
The system SHALL stream topology snapshots for God-View using a versioned Arrow IPC payload contract and a required metadata envelope for deterministic client decoding.

The snapshot schema version `1` MUST use two record batches:
- `nodes` columns:
  - `node_index` (`u32`, required)
  - `node_id` (`utf8`, required)
  - `node_type` (`utf8`, required)
  - `x` (`f32`, required)
  - `y` (`f32`, required)
  - `z` (`f32`, optional; default `0`)
  - `status_code` (`u8`, required; enum-mapped)
  - `causal_class` (`u8`, required; enum-mapped to `root_cause|affected|healthy|unknown`)
  - `severity` (`u8`, optional)
  - `size` (`f32`, optional)
  - `color_rgba` (`fixed_size_binary[4]`, optional)
- `edges` columns:
  - `edge_index` (`u32`, required)
  - `edge_id` (`utf8`, required)
  - `source_index` (`u32`, required; references `nodes.node_index`)
  - `target_index` (`u32`, required; references `nodes.node_index`)
  - `edge_type` (`utf8`, required)
  - `weight` (`f32`, optional)
  - `status_code` (`u8`, optional)
  - `color_rgba` (`fixed_size_binary[4]`, optional)

The metadata envelope MUST be included with each snapshot revision and MUST include:
- `schema_version` (integer, required)
- `snapshot_revision` (monotonic integer, required)
- `generated_at` (RFC3339 timestamp, required)
- `graph_id` (string, required)
- `node_count` and `edge_count` (integer, required)
- `bitmap_version` (integer, required)
- `bitmap_offsets` (object/map, required)
- `flags` (object/map, optional; includes renderer/runtime hints)

#### Scenario: Client accepts supported snapshot schema
- **GIVEN** the server emits a topology snapshot with a supported schema version
- **WHEN** the God-View client receives the payload
- **THEN** the client decodes nodes and edges without JSON transformation
- **AND** the client renders the decoded snapshot revision

#### Scenario: Client handles unsupported snapshot schema
- **GIVEN** the server emits a topology snapshot with an unsupported schema version
- **WHEN** the God-View client receives the payload
- **THEN** the client rejects that snapshot revision
- **AND** the UI displays a recoverable compatibility error state

#### Scenario: Client validates required metadata envelope fields
- **GIVEN** the server emits a snapshot revision
- **WHEN** the client validates envelope metadata
- **THEN** missing required fields cause the revision to be rejected
- **AND** the previous accepted revision remains active

#### Scenario: Client validates required columns for schema version 1
- **GIVEN** the server emits schema version `1`
- **WHEN** the client validates record batch columns
- **THEN** missing required node or edge columns cause the revision to be rejected
- **AND** optional columns may be absent without failing decode

### Requirement: Rustler Arrow Snapshot Encoding
The system MUST produce production God-View snapshot payloads via a Rustler NIF using Arrow IPC-compatible memory layouts; Elixir SHALL orchestrate query/fetch and stream lifecycle but SHALL NOT be the long-term payload encoder.

#### Scenario: Snapshot encode path uses Rust NIF
- **GIVEN** God-View snapshot generation is enabled
- **WHEN** a new topology revision is built
- **THEN** the encode operation executes in the Rust NIF layer
- **AND** the emitted payload is an Arrow IPC-compatible binary buffer

### Requirement: Hybrid Causal Filter Bitmaps
The system SHALL compute causal node-state classifications server-side and emit compact bitmap metadata per snapshot revision so the client can apply visual filtering without recomputing causality.

Causal classes MUST be encoded as:
- `0 = unknown`
- `1 = healthy`
- `2 = affected`
- `3 = root_cause`

Per snapshot revision, the backend MUST emit mutually-exclusive class bitmaps for:
- `causal.root_cause`
- `causal.affected`
- `causal.healthy`
- `causal.unknown`

Each node MUST belong to exactly one causal class in a given revision.

When multiple causal signals apply to a node, class assignment precedence MUST be:
`root_cause` > `affected` > `healthy` > `unknown`.

#### Scenario: Apply causal blast radius states
- **GIVEN** a snapshot revision that includes causal classification bitmaps
- **WHEN** the operator enables blast-radius mode
- **THEN** root-cause nodes render in critical emphasis
- **AND** affected nodes render in degraded emphasis
- **AND** unrelated healthy nodes render in ghosted emphasis

#### Scenario: Toggle visual filters without server round-trip
- **GIVEN** the current snapshot revision and causal bitmaps are loaded
- **WHEN** the operator toggles visual-only filters
- **THEN** the client updates visibility and styling using existing bitmap data
- **AND** no topology recomputation request is sent to the backend

#### Scenario: Causal class exclusivity is preserved
- **GIVEN** a snapshot revision is emitted
- **WHEN** the client inspects class bitmaps for all nodes
- **THEN** no node index is set in more than one causal class bitmap
- **AND** the union of the four class bitmaps covers all emitted nodes

### Requirement: Structural Reshape Contract
The system SHALL distinguish visual-only filter toggles from structural reshape actions, and SHALL require backend recomputation for reshape operations that change layout topology.

#### Scenario: Visual-only filter action
- **WHEN** the operator hides or highlights a class of nodes without changing graph structure
- **THEN** the client applies the change locally from loaded snapshot data

#### Scenario: Structural reshape action
- **WHEN** the operator triggers a collapse or expand operation that changes graph layout
- **THEN** the backend recomputes topology coordinates and relationships
- **AND** the server emits a new snapshot revision

### Requirement: Causal Explainability Surface
The system SHALL provide operator-visible evidence for causal classifications, including confidence and source signals used for each classification decision.

For each node, explainability payload MUST include:
- `causal_class` (`root_cause|affected|healthy|unknown`)
- `confidence` (`0.0..1.0`)
- `signal_categories` (non-empty list for `root_cause` and `affected`, optional otherwise)
- `explanations` (list of concise human-readable reason strings)
- `model_revision` (string identifying the causal model/rule set revision)
- `evaluated_at` (RFC3339 timestamp)

#### Scenario: Inspect root-cause reasoning
- **GIVEN** a node classified as root cause
- **WHEN** the operator opens node details in God-View
- **THEN** the UI shows causal confidence
- **AND** the UI lists the contributing signal categories used for that classification

#### Scenario: Affected-node explainability is available
- **GIVEN** a node classified as affected
- **WHEN** the operator opens node details in God-View
- **THEN** the UI shows confidence and signal categories for the affected classification
- **AND** the UI includes at least one explanation string

#### Scenario: Unknown classification carries explicit uncertainty
- **GIVEN** a node classified as unknown
- **WHEN** the operator opens node details in God-View
- **THEN** the UI shows `causal_class=unknown`
- **AND** the explainability payload indicates insufficient or conflicting evidence

### Requirement: God-View Performance SLOs
The system SHALL enforce measurable performance budgets for God-View interactions and snapshot delivery on supported environments.

#### Scenario: Transition budget for blast-radius mode
- **GIVEN** an already loaded snapshot revision
- **WHEN** the operator toggles blast-radius mode
- **THEN** the visual transition completes within 16 ms on supported environments

#### Scenario: Initial snapshot load budget
- **GIVEN** an authenticated operator opens God-View
- **WHEN** the first usable snapshot is requested
- **THEN** the UI renders the first usable topology frame within 3 seconds on supported environments

### Requirement: GPU Rendering Engine
The system MUST render God-View with `deck.gl` in WebGPU mode on supported browsers/hardware, with an explicit fallback strategy for unsupported clients.

#### Scenario: WebGPU-capable client
- **GIVEN** the operator browser and GPU support the required WebGPU capabilities
- **WHEN** God-View initializes
- **THEN** `deck.gl` runs in WebGPU mode for topology and causal overlay layers

#### Scenario: WebGPU-unsupported client
- **GIVEN** the operator browser or GPU does not support required WebGPU capabilities
- **WHEN** God-View initializes
- **THEN** the UI switches to the documented fallback renderer mode
- **AND** the operator is informed that peak-performance mode is unavailable

### Requirement: Wasm Arrow Execution Layer
The system MUST provide a WebAssembly execution layer for Arrow-backed God-View client operations so high-cardinality compute paths avoid JavaScript object materialization and reduce garbage-collection stalls.

#### Scenario: Three-hop traversal computed in Wasm
- **GIVEN** a loaded God-View snapshot with 100k-class topology data
- **WHEN** an operator requests "within 3 hops" from a selected node
- **THEN** traversal executes in the Wasm layer over Arrow-backed memory
- **AND** the resulting selection mask is applied without backend round-trip for visual-only updates

#### Scenario: Local multi-column filter computed in Wasm
- **GIVEN** a loaded God-View snapshot with node attribute columns
- **WHEN** an operator applies a compound filter such as vendor plus throughput and latency thresholds
- **THEN** the Wasm layer performs a local columnar scan and emits a visibility/ghosting mask
- **AND** frame rendering remains within configured interactive budgets on supported environments

#### Scenario: Layout interpolation computed in Wasm
- **GIVEN** a transition between two coordinate sets for many nodes
- **WHEN** an animated transition is required
- **THEN** intermediate coordinates are computed in the Wasm layer
- **AND** the renderer consumes those coordinates without introducing periodic GC-related stutter

### Requirement: JavaScript GC Pressure Guardrail
The system SHALL keep per-node compute paths and hot-path attribute transformations out of JavaScript for 100k+ snapshots, except where compatibility fallback is explicitly enabled.

#### Scenario: 100k snapshot interaction path
- **GIVEN** God-View is running on a supported client with WebGPU and Wasm enabled
- **WHEN** operators perform repeated filter and selection interactions
- **THEN** node-level compute remains in Wasm/typed-memory paths
- **AND** the runtime avoids periodic main-thread GC spikes attributable to object-per-node transforms

### Requirement: Feature-Flagged Rollout
The system SHALL gate God-View behind an explicit feature flag until performance and reliability acceptance criteria are met.

#### Scenario: Feature disabled
- **GIVEN** the God-View feature flag is disabled for an environment
- **WHEN** a user navigates to God-View routes
- **THEN** the UI does not expose the feature entry point
- **AND** the backend does not emit God-View snapshot streams

#### Scenario: Feature enabled
- **GIVEN** the God-View feature flag is enabled for an environment
- **WHEN** an authorized operator opens God-View
- **THEN** the feature entry point and snapshot stream are available
