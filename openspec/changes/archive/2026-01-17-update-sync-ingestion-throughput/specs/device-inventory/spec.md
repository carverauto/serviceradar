## ADDED Requirements
### Requirement: Conflict-Safe Sync Upserts
The system SHALL upsert device inventory records for sync updates so concurrent batches do not drop updates when devices already exist.

#### Scenario: Duplicate device across concurrent batches
- **WHEN** two sync batches include updates for the same device UID
- **THEN** device ingestion SHALL complete without duplicate key errors
- **AND** the device record SHALL be updated using the latest ingested fields
