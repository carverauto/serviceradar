## 1. Generator
- [x] 1.1 Replace `scripts/db/generate-platform-baseline.sh` with `//build/schema_baseline:generate`, keeping its output for the existing sections byte for byte.
- [x] 1.2 Capture compression settings, compression policies and retention policies.
- [x] 1.3 Capture seed rows, regenerating non-immutable defaults per install.
- [x] 1.4 Refuse to generate when the catalog holds state the generator does not reproduce.

## 2. Baseline and bootstrap
- [x] 2.1 Regenerate the baseline at the same `included_through`.
- [x] 2.2 Remove the hand-maintained seed rows from `SchemaBootstrap`.

## 3. Verification
- [x] 3.1 Freshness contract test: covered seeds and policies must be in the baseline.
- [x] 3.2 Bootstrap integration test: policy state equals the replayed lane database; seeded rows are present.

## 4. Existing installs
- [x] 4.1 Repair databases already created from a baseline without seed rows or policy state: `BaselineInstallRepairWorker`, enqueued once on baseline-created databases by migration `20261115233000_repair_baseline_install_state`.
