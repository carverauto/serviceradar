## ADDED Requirements
### Requirement: Soft-deleted devices reactivate on new sightings
When a device marked as deleted is observed again with a non-deletion update, the system SHALL clear deletion flags so the device returns to the active inventory.

#### Scenario: Re-sighted device clears deletion flag
- **WHEN** an incoming device update for `sr:device-123` does not set `_deleted` or `deleted`
- **THEN** the upsert removes any prior `_deleted`/`deleted` flags and the device appears in inventory queries.

#### Scenario: Explicit deletion remains honored
- **WHEN** an incoming update includes `_deleted=true`
- **THEN** the device remains excluded from active inventory and continues to satisfy unique-IP constraints for soft deletions.
