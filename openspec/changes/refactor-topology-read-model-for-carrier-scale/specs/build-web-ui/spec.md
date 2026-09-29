## ADDED Requirements

### Requirement: God-View default topology is a bounded tile overview
The God-View overview SHALL show infrastructure-first quadtree tiles with stable aggregates for hidden endpoint membership, using bounded feature and encoded-byte budgets independently of total inventory size.

#### Scenario: Dense inventory remains represented
- **GIVEN** the invented million-device hierarchy is available
- **WHEN** an operator opens God-View at zoom zero
- **THEN** the overview SHALL render bounded server-positioned infrastructure and aggregate glyphs
- **AND** aggregate counts plus individually represented devices SHALL account for all admitted membership
- **AND** search and bounded detail navigation SHALL keep every admitted device reachable

### Requirement: God-View map and detail geometry have explicit authorities
The God-View overview SHALL render persistent server-authored world coordinates. Browser ELK SHALL own only a bounded detail scene entered explicitly from the map; the client SHALL NOT mix map and detail placement or perform a second layout pass over accepted geometry.

#### Scenario: Tile geometry remains stable across navigation
- **WHEN** the operator pans, zooms, or reloads the map
- **THEN** the accepted layout version SHALL provide the same world coordinates
- **AND** the client SHALL apply only the declared UInt16 tile-local affine transform and camera transform

#### Scenario: Partial zoom loading preserves coherent coverage
- **GIVEN** some visible target-zoom tiles are still unavailable
- **WHEN** the client prepares a zoom-level transition
- **THEN** it SHALL retain compatible same-zoom coverage until the target coverage is ready
- **AND** it SHALL NOT join incompatible parent and child boundary portals in the rendered frame

#### Scenario: Detail entry preserves map state
- **WHEN** the operator opens a neighborhood, component/aggregate-member, or rendered-bundle-member page
- **THEN** the client SHALL enter one bounded ELK coordinate space
- **AND** returning SHALL restore the map camera and compatible cached tiles
- **AND** detail layout SHALL NOT move the map's device positions
- **AND** continuation SHALL retain the displayed publication and tile identity rather than mix detail pages from different generations

### Requirement: God-View bootstraps visible tiles over HTTP
The God-View surface SHALL load a bounded layout manifest, visible schema-3 tiles and separate bounded telemetry overlay bodies over HTTP independently of channel timing. The channel SHALL deliver only bounded geometry and overlay invalidation metadata, with explicit reset markers on overflow. Overlay refresh SHALL preserve compatible cached geometry and SHALL retain explicit unknown or partial telemetry coverage.

#### Scenario: First load does not wait for a stream snapshot
- **GIVEN** an accepted layout has low-zoom tiles available
- **WHEN** the operator opens God-View before channel delivery
- **THEN** the UI SHALL request and render the visible HTTP tiles
- **AND** it SHALL NOT wait for a channel graph payload

#### Scenario: Stream disruption preserves cached geometry
- **GIVEN** a valid map has rendered
- **WHEN** its channel disconnects
- **THEN** the UI SHALL retain compatible geometry
- **AND** reconnect SHALL reconcile publication and overlay identities
- **AND** only required visible dirty tiles SHALL be refetched

### Requirement: God-View enforces tile and detail density budgets
The server SHALL enforce separate node, relation, label, member, total-feature, and encoded-byte budgets before delivering tiles or bounded details. Tile overflow SHALL generalize with conserved membership; detail overflow SHALL use bounded pages or summaries. Labels and edge details SHALL remain readable within the selected presentation density.

#### Scenario: Maximum-zoom overflow remains discoverable
- **GIVEN** a tile remains denser than its budgets at maximum zoom
- **WHEN** it is generated
- **THEN** bounded aggregates SHALL retain correct counts and detail references
- **AND** the tile SHALL NOT transmit an oversized member list or silently drop members

#### Scenario: Detail expansion cannot grow the world graph
- **GIVEN** an attachment group exceeds its bounded detail budget
- **WHEN** it is expanded
- **THEN** only one bounded member page and required context SHALL enter ELK
- **AND** the map SHALL retain its original persistent coordinates and bounded tiles

### Requirement: God-View distinguishes local health from evidence-backed impact
The God-View surface SHALL render `Affected` or equivalent impact states only when supported by qualifying causal evidence, and SHALL NOT infer a blast radius solely from graph proximity to an unhealthy node.

#### Scenario: Unhealthy nodes without causal evidence do not paint blast radius
- **GIVEN** one or more nodes are unhealthy from availability state alone
- **AND** no qualifying causal evidence path is present
- **WHEN** the topology surface renders status overlays
- **THEN** only the unhealthy or unknown local node state SHALL be shown
- **AND** neighboring nodes SHALL NOT be marked `Affected` solely because they are within a hop budget

#### Scenario: Evidence-backed impact path renders affected state
- **GIVEN** qualifying causal evidence identifies an impact path through the visible topology
- **WHEN** the topology surface renders status overlays
- **THEN** nodes on that evidence-backed path SHALL render as impacted
- **AND** the UI SHALL preserve operator-visible attribution for why those nodes are marked impacted
