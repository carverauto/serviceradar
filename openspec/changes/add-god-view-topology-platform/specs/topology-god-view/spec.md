## ADDED Requirements
### Requirement: Versioned Binary Topology Snapshots
The system SHALL stream topology snapshots for God-View using a versioned binary payload contract that includes node geometry/state, edge geometry/state, and metadata needed for deterministic client decoding.

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

### Requirement: Rustler Arrow Snapshot Encoding
The system MUST produce production God-View snapshot payloads via a Rustler NIF using Arrow IPC-compatible memory layouts; Elixir SHALL orchestrate query/fetch and stream lifecycle but SHALL NOT be the long-term payload encoder.

#### Scenario: Snapshot encode path uses Rust NIF
- **GIVEN** God-View snapshot generation is enabled
- **WHEN** a new topology revision is built
- **THEN** the encode operation executes in the Rust NIF layer
- **AND** the emitted payload is an Arrow IPC-compatible binary buffer

### Requirement: Hybrid Causal Filter Bitmaps
The system SHALL compute causal node-state classifications server-side and emit compact bitmap metadata per snapshot revision so the client can apply visual filtering without recomputing causality.

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
The system SHALL provide operator-visible evidence for causal classifications, including confidence and source signals used for each root-cause decision.

#### Scenario: Inspect root-cause reasoning
- **GIVEN** a node classified as root cause
- **WHEN** the operator opens node details in God-View
- **THEN** the UI shows causal confidence
- **AND** the UI lists the contributing signal categories used for that classification

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
