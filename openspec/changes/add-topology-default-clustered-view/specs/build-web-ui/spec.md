## ADDED Requirements
### Requirement: God-View defaults to backend-authored clustered endpoint summaries
The God-View topology canvas SHALL default to a backend-authored clustered endpoint summary view when dense endpoint attachments are present, so the default graph emphasizes readable infrastructure topology over fully expanded endpoint leaves.

#### Scenario: Dense endpoint fan-out defaults to clustered summaries
- **GIVEN** the topology snapshot contains infrastructure nodes plus many discovered endpoint attachments on one or more access devices
- **WHEN** an operator opens the default God-View topology view with the `endpoints` layer enabled
- **THEN** the canvas SHALL render backend-authored endpoint cluster summary nodes instead of rendering every endpoint leaf by default
- **AND** the backbone infrastructure topology SHALL remain visually primary

#### Scenario: Cluster summaries preserve operator context
- **GIVEN** the topology snapshot includes one or more endpoint cluster summary nodes
- **WHEN** the canvas renders those cluster nodes
- **THEN** each cluster node SHALL expose aggregate member count and summarized state metadata
- **AND** the cluster node SHALL remain anchored to the relevant infrastructure topology context

### Requirement: God-View cluster expansion is explicit and backend-driven
God-View SHALL allow operators to explicitly expand clustered endpoint summaries, and the resulting expanded view SHALL be produced by the backend snapshot pipeline rather than by frontend-authored clustering or layout logic.

#### Scenario: Expand a clustered endpoint summary
- **GIVEN** the default topology view shows an endpoint cluster summary node
- **WHEN** an operator requests expansion for that cluster
- **THEN** God-View SHALL request and render a new backend-authored snapshot that reveals the member endpoints
- **AND** the expansion SHALL preserve the surrounding backbone layout contract
- **AND** the revealed endpoints SHALL be arranged in a backend-authored spiral or radial fan-out around the owning topology anchor

#### Scenario: Collapse returns to clustered summary view
- **GIVEN** a cluster has been expanded to show member endpoints
- **WHEN** the operator collapses that cluster or exits expansion mode
- **THEN** God-View SHALL return to the clustered summary representation for that endpoint group
- **AND** the resulting view SHALL again be based on backend-authored cluster membership and coordinates

#### Scenario: Spiral expansion remains backend-authored
- **GIVEN** a cluster has been expanded in the topology view
- **WHEN** member endpoints are rendered around the cluster anchor
- **THEN** the frontend SHALL render the coordinates supplied by the backend snapshot
- **AND** the frontend SHALL NOT compute its own spiral, radial, or force-directed expansion geometry

### Requirement: Endpoint layer toggles remain coherent with clustered summaries
The God-View `endpoints` layer SHALL control both clustered endpoint summaries and expanded endpoint leaves without hiding backbone infrastructure.

#### Scenario: Endpoints disabled with clustered default view
- **GIVEN** the topology snapshot contains backbone links and clustered endpoint summary nodes
- **WHEN** the operator disables the `endpoints` layer
- **THEN** clustered endpoint summaries and any expanded endpoint leaves SHALL be hidden
- **AND** backbone infrastructure nodes and links SHALL remain visible

#### Scenario: Endpoints enabled after being disabled
- **GIVEN** the operator previously disabled the `endpoints` layer
- **WHEN** the operator re-enables the `endpoints` layer
- **THEN** the default view SHALL restore clustered endpoint summaries
- **AND** the system SHALL NOT require the frontend to recompute cluster membership or layout

### Requirement: Dense endpoint fixtures regress on default view readability
Automated God-View tests SHALL fail if dense endpoint-heavy topology fixtures render as an unreadable fully expanded default view instead of a clustered summary view.

#### Scenario: Dense access-layer regression coverage
- **GIVEN** automated topology tests execute against a fixture containing an access device with many downstream endpoints
- **WHEN** the default God-View topology snapshot is built and rendered
- **THEN** tests SHALL fail if the default view renders every endpoint leaf instead of clustered summaries
- **AND** tests SHALL fail if cluster expansion requires frontend-authored layout behavior
