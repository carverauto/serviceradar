## ADDED Requirements

### Requirement: DeviceRecord clone isolation
The device registry MUST return `DeviceRecord` values whose mutable fields do not alias internal stored state or other returned clones, including when those fields are empty-but-non-nil.

#### Scenario: Empty metadata maps are deep-copied
- **GIVEN** a stored `DeviceRecord` has `Metadata` set to an empty (but non-nil) map
- **WHEN** a caller retrieves a copy via a registry getter that uses `cloneDeviceRecord`
- **THEN** the returned `Metadata` MUST be a distinct map instance from the stored record
- **AND** mutating the returned `Metadata` MUST NOT change the stored record’s `Metadata`

#### Scenario: Empty slices are non-aliased
- **GIVEN** a stored `DeviceRecord` has `DiscoverySources` and/or `Capabilities` set to empty-but-non-nil slices (including cases with non-zero capacity)
- **WHEN** a caller retrieves a copy via a registry getter that uses `cloneDeviceRecord`
- **THEN** appending to the returned slices MUST NOT affect the stored record’s slices
- **AND** subsequent clones MUST NOT observe values appended to earlier clones

#### Scenario: Clone mutation does not affect other clones
- **GIVEN** two callers retrieve independent clones of the same stored `DeviceRecord`
- **WHEN** one caller mutates its clone’s `Metadata` (e.g., sets a new key)
- **THEN** the other caller’s clone MUST NOT reflect that mutation

