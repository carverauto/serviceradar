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
