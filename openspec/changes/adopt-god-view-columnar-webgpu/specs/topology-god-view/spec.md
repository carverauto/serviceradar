## MODIFIED Requirements

### Requirement: Versioned Binary Topology Snapshots
The system SHALL stream topology snapshots for God-View using a versioned Arrow IPC payload contract and a required metadata envelope for deterministic client decoding.

The snapshot schema version `3` MUST use one record batch in which node rows come first and edge rows follow, with `node_count` and `edge_count` recorded in the Arrow schema metadata. Every numeric column is therefore dense over rows `0..node_count` for nodes and `node_count..node_count + edge_count` for edges, and a decoder MUST be able to slice positions, states and endpoints without branching on `row_type` or parsing JSON.
- Node columns:
  - `node_x`, `node_y` (`u16`, quantized layout coordinates; compatibility hints, non-authoritative for ELK scene geometry)
  - `node_state` (`u16`, enum-mapped causal class)
  - `node_label` (`utf8`)
  - `node_pps` (`u32`)
  - `node_oper_up` (`u8`)
  - `node_details` (`utf8`, JSON)
- Edge columns:
  - `edge_source`, `edge_target` (`u32`, required for edge rows; node row indexes, so snapshots above 65535 nodes can name both endpoints)
  - `edge_pps`, `edge_pps_ab`, `edge_pps_ba` (`u32`)
  - `edge_flow_bps`, `edge_flow_bps_ab`, `edge_flow_bps_ba`, `edge_capacity_bps` (`u64`)
  - `edge_telemetry_eligible` (`u8`)
  - `edge_label`, `edge_topology_class`, `edge_protocol`, `edge_evidence_class` (`utf8`)
  - `edge_details` (`utf8`, JSON)
- Details columns: every details key read for every row by rendering, filtering, clustering, labeling or layout MUST also be emitted as a typed column named `node_detail_<key>`, `edge_detail_<key>` or `edge_metadata_<key>` (text `utf8`, number `f64`, flag `u8`). These are derived from the same JSON the row ships, so a column never disagrees with its row. `edge_has_metadata`, `edge_has_sparkline` and `details_irregular` (`u8`) accompany them; `details_irregular` marks a row with a value a column cannot carry exactly.
- `row_type` (`i8`), `snapshot_schema_version` (`u32`) and `snapshot_revision` (`u64`) are present on every row.

The metadata envelope MUST be included with each snapshot revision and MUST include:
- `schema_version` (integer, required)
- `snapshot_revision` (monotonic integer, required)
- `generated_at` (RFC3339 timestamp, required)
- `graph_id` (string, required)
- `node_count` and `edge_count` (integer, required)
- `bitmap_version` (integer, required)
- `bitmap_offsets` (object/map, required)
- `flags` (object/map, optional; includes renderer/runtime hints)

Backend `x`, `y`, or equivalent coordinate fields SHALL NOT be authoritative for the ELK scene path. The frontend SHALL derive every accepted visible coordinate and route from the bounded semantic graph through its single ELK geometry authority.

#### Scenario: Client accepts supported snapshot schema
- **GIVEN** the server emits a topology snapshot with a supported schema version
- **WHEN** the God-View client receives the payload
- **THEN** the client decodes nodes and edges into typed columns without parsing details JSON
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

#### Scenario: Client validates required columns for schema version 3
- **GIVEN** the server emits schema version `3`
- **WHEN** the client validates the record batch columns
- **THEN** missing required node or edge columns cause the revision to be rejected
- **AND** absent details columns fall back to parsing that row's details JSON

#### Scenario: Endpoint indexes above 65535 round-trip
- **GIVEN** a snapshot with more than 65535 nodes and edges whose endpoints index nodes above 65535
- **WHEN** the snapshot is encoded by the server and decoded by the client
- **THEN** every edge resolves to the node rows it names
- **AND** the decoded position column has length twice the node count

#### Scenario: Legacy coordinate hints do not become a second authority
- **GIVEN** a supported snapshot contains finite `node_x` and `node_y` compatibility hints
- **WHEN** the ELK scene path lays out the bounded visible graph
- **THEN** the client SHALL NOT apply those hints as accepted node positions
- **AND** all accepted coordinates and routes SHALL come from the decoded ELK result

### Requirement: GPU Rendering Engine
The system MUST render God-View with `deck.gl` on a WebGPU device only, and MUST NOT construct a WebGL renderer for God-View.

The reported renderer mode reflects the device deck.gl actually created, not the presence of `navigator.gpu`. Other deck.gl consumers in the web UI are not governed by this requirement.

#### Scenario: WebGPU-capable client
- **GIVEN** the operator browser and GPU support WebGPU at the default device limits
- **WHEN** God-View initializes
- **THEN** `deck.gl` is constructed with a WebGPU device request
- **AND** the renderer mode is `webgpu` only after deck.gl reports a WebGPU device

#### Scenario: WebGPU-unsupported client
- **GIVEN** the operator browser lacks `navigator.gpu`, or its adapter or device request fails
- **WHEN** God-View initializes
- **THEN** the topology surface shows a visible "WebGPU required" state and logs the reason
- **AND** no WebGL deck.gl instance is constructed

#### Scenario: Device lost or rejected work at runtime
- **GIVEN** God-View is rendering on a WebGPU device
- **WHEN** the device is lost or reports an uncaptured validation error
- **THEN** the renderer is torn down and a visible renderer-stopped state is shown and logged
- **AND** the canvas is not left silently blank

### Requirement: JavaScript GC Pressure Guardrail
The system SHALL keep per-node compute paths and hot-path attribute transformations out of JavaScript object materialization for large snapshots.

One object-graph materialization per accepted snapshot is permitted where layout still needs it.

#### Scenario: 100k snapshot interaction path
- **GIVEN** God-View is running on a supported client with WebGPU and Wasm enabled
- **WHEN** operators perform repeated filter, hover, selection and camera interactions
- **THEN** node-level compute remains in Wasm/typed-memory paths and no per-node records are rebuilt
- **AND** the runtime avoids periodic main-thread GC spikes attributable to object-per-node transforms

#### Scenario: Details parsed on demand
- **GIVEN** an accepted snapshot whose details keys are served from columns
- **WHEN** the snapshot is decoded, laid out, rendered, filtered and hovered
- **THEN** no node or edge details JSON is parsed
- **AND** opening the details of a picked node parses only that node's JSON

## ADDED Requirements

### Requirement: GPU Packet Flow Rendering
The system SHALL render God-View packet flow on the GPU from per-edge instance data, animated by a time uniform, within the WebGPU default vertex-buffer limit.

#### Scenario: Animation does not rebuild the scene
- **GIVEN** packet flow is enabled on telemetry-eligible edges
- **WHEN** the animation advances
- **THEN** only the time uniform of the packet-flow layer changes
- **AND** no graph render pass or per-particle JavaScript data is rebuilt for the frame

#### Scenario: Pipeline fits default device limits
- **GIVEN** a WebGPU device created with default limits
- **WHEN** the packet-flow pipeline is created
- **THEN** it uses no more than 8 vertex buffers
- **AND** the device reports no validation error

#### Scenario: Every eligible edge carries particles
- **GIVEN** a snapshot with more eligible edges than a fixed global particle cap would cover
- **WHEN** packet flow renders
- **THEN** every eligible visible edge draws particles
- **AND** density is thinned evenly across edges when the per-frame particle budget is exceeded
