## 1. Baseline Definition
- [x] 1.1 Define the baseline artifact format, location, checksum, and included migration version marker.
- [x] 1.2 Add tooling to generate the baseline from a clean migration replay database.
- [x] 1.3 Add tooling to compare a baseline-created schema against a migration-replayed schema.

## 2. Startup Bootstrap
- [x] 2.1 Implement database classification for empty, migrated, and ambiguous states.
- [x] 2.2 Apply the baseline only for proven-empty databases.
- [x] 2.3 Insert migration ledger rows for all versions included in the baseline.
- [x] 2.4 Preserve normal pending-migration behavior for existing deployments.
- [x] 2.5 Fail closed with actionable diagnostics for ambiguous partial databases.

## 3. Maintenance Separation
- [x] 3.1 Inventory migrations that perform backfills, cleanup updates, continuous aggregate refreshes, or operational repair work.
- [x] 3.2 Convert install-critical maintenance into post-bootstrap idempotent jobs or documented operator tasks.
- [x] 3.3 Ensure new migrations do not run empty-database backfills or CAGG refreshes synchronously during first boot.

## 4. Deployment Paths
- [x] 4.1 Update Docker Compose migration/bootstrap service flow for baseline-first clean installs.
- [x] 4.2 Update Helm migration/bootstrap job flow for baseline-first clean installs.
- [x] 4.3 Document behavior for clean installs, upgrades, and ambiguous database repair.

## 5. Verification
- [x] 5.1 Add unit tests for database classification and baseline marker handling.
- [x] 5.2 Add integration tests for baseline bootstrap and existing-database migration upgrade.
- [x] 5.3 Add CI schema-diff validation between baseline and migration replay.
- [x] 5.4 Add Docker Compose clean-install smoke timing coverage.
- [x] 5.5 Validate `docker compose down -v && docker compose up -d` reaches healthy services inside the target startup window.
