## ADDED Requirements
### Requirement: Worker assignment visibility uses runtime-derived source of truth
The platform SHALL derive worker assignment visibility from the authoritative analysis dispatch runtime rather than from stale registry metadata.

#### Scenario: Runtime snapshot backs assignment visibility
- **WHEN** current assignment visibility is requested for a registered camera analysis worker
- **THEN** the platform SHALL use the active dispatch snapshot as the source of truth
- **AND** it SHALL NOT require persistent assignment records in the worker registry
