# Vantage ML Extensibility E2E Test Suite

This package houses the requirement-driven, opaque-box 4-tier E2E test suite for
ServiceRadar Vantage ML extensibility (`add-vantage-ml-extensibility`).

## Master Test Catalog

`fixtures/test_catalog.json` merges all 4 tiers into **180** cataloged test cases:
- **Tier 1 & Tier 2** (`158` cases across `F1`-`F14`):
  - `fixtures/catalog_f1_f5.json` (`50` cases)
  - `fixtures/catalog_f6_f10.json` (`60` cases)
  - `fixtures/catalog_f11_f14.json` (`48` cases)
- **Tier 3** (`15` pairwise cross-feature combinations, `E2E-T3-01`..`E2E-T3-15`)
- **Tier 4** (`7` real-world operational workloads, `E2E-T4-W1`..`E2E-T4-W7`)

Extended cross-feature and workload scenario vectors live in `fixtures/t3_t4/*.json`.

## Execution Modes

### Mode A (Hermetic, Pure Python 3.11+ Stdlib)
Mode A validates wire envelopes, read-grant contracts, signal schemas,
crop-box geometry, Baseline Sequential JFIF JPEG generation/parsing,
deterministic POSIX.1-1988 USTAR archives, Solution Pack v1/v2 manifests,
secret-free and synthetic-data hygiene, fail-closed driver guards, Tier 3/4
cross-feature contracts, and master `fixtures/test_catalog.json` completeness
with zero third-party dependencies.

Mode A test modules (`7` total, wired into `//integration_tests/vantage_ml:mode_a_tests`):
- `test_mode_a_contracts.py` (`:mode_a_contracts_test`)
- `test_mode_a_synthetic_media.py` (`:mode_a_synthetic_media_test`)
- `test_mode_a_f1_f5.py` (`:mode_a_f1_f5_test`)
- `test_mode_a_pack_v2.py` (`:mode_a_pack_v2_test`)
- `test_mode_a_f6_f10.py` (`:mode_a_f6_f10_test`)
- `test_mode_a_f11_f14.py` (`:mode_a_f11_f14_test`)
- `test_mode_a_tier3_tier4.py` (`:mode_a_tier3_tier4_test`)

Run via Bazel RBE:
```sh
bazel test --config=remote //integration_tests/vantage_ml:mode_a_tests
```

Run directly with Python `unittest`:
```sh
python3 -m unittest discover -s integration_tests/vantage_ml -p "test_mode_a_*.py" -v
```

### Mode B (Live Cross-Component E2E)
Mode B tests exercise live Elixir (`serviceradar_core`, `serviceradar_core_elx`,
`web-ng`), Rust (`media-core`, `media-worker`, `srql`), `@carverauto/serviceradar-cli`,
NATS JetStream, CNPG, and companion `serviceradar-sdk-vantage` workers. Mode B
Bazel targets carry `tags = ["acceptance_test", "manual"]` so `make test` and
PR unit sweeps remain hermetic. Drivers under `drivers/` and all Mode B modules
fail closed (raising `RuntimeError` or `AssertionError`) when any required binary,
module, dependency, or service endpoint is unavailable.

Mode B test modules (`4` total, `131` test methods, wired into `//integration_tests/vantage_ml:mode_b_tests`):
- `test_mode_b_f1_f5.py` (`:mode_b_f1_f5_test`, `51` tests)
- `test_mode_b_f6_f10.py` (`:mode_b_f6_f10_test`, `10` tests)
- `test_mode_b_f11_f14.py` (`:mode_b_f11_f14_test`, `48` tests)
- `test_mode_b_tier3_tier4.py` (`:mode_b_tier3_tier4_test`, `22` tests)

Run via Python `unittest` (requires live CNPG, NATS JetStream, `web-ng`, built JS CLI, and companion SDK):
```sh
python3 -m unittest discover -s integration_tests/vantage_ml -p "test_mode_b_*.py" -v
```

Run via Bazel RBE with live runtime environment configured:
```sh
bazel test --config=remote //integration_tests/vantage_ml:mode_b_tests
```

## Scratch & Temp Directory Convention
All Mode B temporary media, CLI home directories, NATS stores, and `uv`/`maturin`
virtual environments MUST live under `VANTAGE_E2E_SCRATCH_DIR`, which defaults
to `/Volumes/Build/scratch/vantage-ml-e2e/`. Never write scratch files under
`/tmp` or inside the repository checkout.

## Synthetic Fixture Conventions
All fixtures, vectors, and media use strictly synthetic identifiers and
permissive/Apache-2.0 tooling:
- Plates: `SR-0100`, `TEST-742`
- Cameras: `Gate West 01`, `Bay 04 Approach`
- IPv4 CIDRs: RFC 5737 (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`)
- Domains: `example.com`, `example.org`, `example.net`
- Phone numbers: `555-0100` through `555-0199`
