## ADDED Requirements

### Requirement: Topology node hydration is complete
God-view snapshot construction MUST load the device row for every topology node id it intends to render. Hydration MUST page or stream until those ids are loaded. The unplaced-device viewport MAY remain a bounded sample.

#### Scenario: Graph larger than one device page
- **WHEN** a topology graph contains more node ids than one default page of `Device.read`
- **THEN** the snapshot SHALL include a hydrated node for every such id
- **AND** an id that failed to load SHALL NOT be dropped as if the device did not exist
