# Change: Add End-to-End Inventory Count Validation

## Why

Recent regressions in the Device Registry (specifically around IP canonicalization, merges, and churn handling) have caused significant "inventory collapse" where 50,000+ input devices resulted in only ~360 or ~49,000 stored devices.

These issues were only detected after deployment to the demo environment. We need a distinct, automated Gatekeeper that guarantees **Input Cardinality ≈ Output Cardinality** for our standard Faker dataset.

If the Faker generates 50,000 unique Armis devices, the database **MUST** contain 50,000 unique canonical records. Any deviation indicates a logic bug in identity resolution or deduplication.

## What

Implement a dedicated End-to-End (E2E) test suite that:
1.  Connects to a live ServiceRadar environment (specifically targeting the `srql-fixtures` namespace or a dedicated CI ephemeral stack).
2.  Triggers/Waits for the "Faker" agent to complete a full synchronization of its 50k device dataset.
3.  Directly queries the CNPG database (`unified_devices`) to verify the count of canonical devices.
4.  Asserts that `COUNT(*) >= 50,000` (or exact match if environment is isolated).
5.  Validates no "Black Hole" merges (e.g., checks for high counts of `_merged_into` pointing to non-existent targets).

## How

### 1. Test Harness (`tests/e2e/inventory`)
Create a Go-based integration test suite that uses:
-   **Core Client:** To query API status and potentially trigger syncs.
-   **DB Client:** To execute SQL assertions against CNPG.
-   **Environment Config:** `SR_E2E_API_URL`, `SR_E2E_DB_DSN`.

### 2. Execution Flow
1.  **Setup:** Ensure target DB is clean (or account for baseline).
2.  **Trigger:** Wait for Faker agent to report "Sync Complete" or monitor `device_ingest_count` metric.
3.  **Stabilize:** Wait for async queues (AGE graph, search index) to drain (optional, mostly concerned with Postgres persistence here).
4.  **Assert:**
    -   `SELECT COUNT(*) FROM unified_devices WHERE (metadata->>'_merged_into' IS NULL OR metadata->>'_merged_into' = device_id) AND ...`
    -   Expect `50,002` (Faker fixed seed count).
5.  **Diagnose:** If count fails, run diagnostic queries (top merge targets, orphan tombstones) and dump to logs.

### 3. CI Integration
-   Add a Github Action / BuildBuddy step that runs this test against the `srql-fixtures` cluster (or Kind) on nightly builds or pre-release tags.

## Success Criteria
-   The test passes effectively on the current `demo` namespace (proving the fix works).
-   The test fails if we re-introduce the "Weak vs Strong" merge bug (proving it catches regressions).
