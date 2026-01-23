## 1. Investigation

- [x] 1.1 Verify that AshPostgres generates `ON CONFLICT (columns)` when using `upsert_identity`
- [x] 1.2 Check if there's a configuration issue causing constraint name matching instead of column matching
- [x] 1.3 Test the current upsert behavior in isolation to reproduce the issue

## 2. Implementation

- [x] 2.1 Update Interface resource create action to handle conflicts on primary key columns
- [x] 2.2 Add error handling in `insert_bulk/4` to catch TimescaleDB constraint violations
- [x] 2.3 Filter out duplicate records when constraint violation occurs and retry
- [x] 2.4 Treat TimescaleDB chunk-prefixed pkey violations as successful (duplicates skipped)

## 3. Testing

- [ ] 3.1 Test interface ingestion with duplicate records in same batch
- [ ] 3.2 Test interface ingestion with records that already exist in database
- [ ] 3.3 Verify no data loss when duplicates are skipped
- [ ] 3.4 Test across multiple TimescaleDB chunks (different time ranges)
