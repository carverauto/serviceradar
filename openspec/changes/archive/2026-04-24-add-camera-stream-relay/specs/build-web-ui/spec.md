## ADDED Requirements
### Requirement: God-View camera nodes can open live viewers
The God-View topology experience SHALL allow operators to open a live viewer from a camera-capable endpoint node when camera stream inventory is available.

#### Scenario: Open live viewer from one camera node
- **GIVEN** the topology payload includes an endpoint node with camera stream metadata
- **WHEN** an operator selects that node and requests live view
- **THEN** the UI SHALL request an authorized relay session for that camera
- **AND** SHALL render the returned live viewer surface inline or in the associated camera panel

### Requirement: Camera cluster selection opens a tiled viewer
The God-View topology experience SHALL support opening a bounded tiled viewer for a selected cluster or set of camera-capable nodes.

#### Scenario: Open multiple camera tiles from a selection
- **GIVEN** an operator selects multiple camera-capable nodes in the topology view
- **WHEN** they request live view for the selection
- **THEN** the UI SHALL open a tiled viewer grid for the selected cameras
- **AND** SHALL cap or defer additional tiles beyond the supported live-view limit

### Requirement: Viewer errors are operator-visible
The UI SHALL distinguish unavailable camera streams from loading states so operators can tell whether a stream is still connecting, requires credentials, or failed to start.

#### Scenario: Relay session fails for one camera tile
- **GIVEN** a tiled viewer containing multiple selected cameras
- **WHEN** one relay session fails to start
- **THEN** the failed tile SHALL show an explicit unavailable or error state
- **AND** other healthy tiles SHALL continue rendering
