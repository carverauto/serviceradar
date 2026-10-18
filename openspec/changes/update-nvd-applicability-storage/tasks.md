## 1. Implementation

- [x] 1.1 Normalize NVD configurations once per advisory and reference them from coordinates (expression version 3).
- [x] 1.2 Persist `nvd_configurations` on the advisory row in the same upsert as the advisory.
- [x] 1.3 Resolve configuration references in the matcher with one bounded query per chunk of matched advisories; keep version 2 rows readable.
- [x] 1.4 Omit `nvd_configurations` from SRQL advisory rows.
- [x] 1.5 Add the migration and advance `core.migrations.expectedVersion`.

## 2. Verification

- [x] 2.1 Unit test: stored applicability bytes grow linearly with a record's coordinates.
- [x] 2.2 Integration test: referenced and version 2 rows adjudicate identically.
- [x] 2.3 Integration test: the loader stores and replaces configurations with the advisory.
- [x] 2.4 Differential run of the old and new normalizers over the public NVD feeds.
