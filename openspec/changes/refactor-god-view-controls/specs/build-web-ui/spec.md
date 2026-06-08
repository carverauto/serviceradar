## ADDED Requirements
### Requirement: God-View deck.gl map interaction controls
The God-View topology map SHALL provide direct deck.gl camera controls for pan, zoom, reset, and fit actions. The controls SHALL preserve NetFlow-like interaction semantics for topology without changing the NetFlow map implementation.

#### Scenario: Pointer-focal wheel zoom
- **GIVEN** an operator is viewing the God-View topology map
- **WHEN** they zoom with the mouse wheel or trackpad over a map point
- **THEN** the map zooms around that pointer focal point
- **AND** the point under the cursor remains stable aside from clamp limits

#### Scenario: Thresholded pan preserves click interactions
- **GIVEN** an operator starts a pointer gesture on the God-View topology map
- **WHEN** pointer movement stays below the configured pan threshold
- **THEN** the gesture is treated as a click-capable interaction
- **AND** the map does not suppress the next click

#### Scenario: Direct map controls update deck camera locally
- **GIVEN** God-View renders topology map controls
- **WHEN** the operator clicks zoom in, zoom out, reset, or fit
- **THEN** the God-View deck camera updates locally
- **AND** the controls are usable without LiveView round trips for purely visual camera changes

### Requirement: God-View deck.gl controls use shared interaction semantics
The God-View topology map SHALL use the shared map interaction controls through a deck.gl orthographic adapter. Direct pan and zoom interactions SHALL update deck.gl `viewState` consistently with NetFlow-style map controls while preserving God-View zoom-tier rendering semantics.

#### Scenario: God-View wheel zoom preserves graph focal point
- **GIVEN** God-View is rendered with deck.gl
- **WHEN** an operator wheel-zooms over a topology node or edge
- **THEN** the deck.gl `viewState.zoom` and `viewState.target` are updated together
- **AND** the graph position under the pointer remains stable aside from min/max zoom clamps
- **AND** the zoom tier is updated when God-View is in automatic zoom mode

#### Scenario: God-View reset returns to latest graph fit
- **GIVEN** an operator has manually panned or zoomed God-View
- **WHEN** they activate reset
- **THEN** God-View clears the manual camera lock
- **AND** recomputes auto-fit from the latest graph
- **AND** preserves any required structural collapse behavior before fitting

### Requirement: God-View LiveView responsibility boundaries
The God-View LiveView SHALL be decomposed into idiomatic Elixir modules with clear responsibilities. The LiveView entrypoint SHALL remain a thin process boundary for mount, render delegation, event delegation, and message handling; stream state, MTR overlay loading, camera relay workflows, tiled camera relay workflows, client performance telemetry, template rendering, and control-state transformations SHALL live in dedicated modules.

#### Scenario: LiveView delegates stream and overlay workflows
- **GIVEN** God-View receives client stream stats, stream errors, or MTR layer toggle events
- **WHEN** the LiveView handles those events
- **THEN** it delegates normalization, retry-state decisions, performance telemetry, and overlay payload construction to dedicated modules
- **AND** the LiveView does not embed graph-query or telemetry-normalization bulk inline

#### Scenario: LiveView delegates camera relay workflows
- **GIVEN** God-View receives single-camera or cluster-camera relay events
- **WHEN** the LiveView handles those events or relay refresh messages
- **THEN** it delegates authorization-aware relay session transitions, tile updates, and viewer-state derivation to dedicated modules
- **AND** the resulting assigns and flash messages remain equivalent to the existing user-visible behavior
