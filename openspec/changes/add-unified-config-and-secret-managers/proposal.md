# Unified Configuration and Secret Managers

## Why

Environment configuration is defined in three places that nothing reconciles, and they have
measurably diverged. From `openspec/notes/env-var-inventory.md` (2026-08-17):

- `.bazelrc` forwards **45** names; the integration-test code reads **58**.
- **26** are read but never forwarded, so they silently take a default. `PGSSLTARGETNAME` and
  `SRQL_TEST_DATABASE_SSLMODE` are TLS-affecting and permanently inert.
- **13** are forwarded but unread by those suites.
- One setting has up to **three spellings**: `.bazelrc` forwards `NATS_CA_FILE`, Go reads
  `NATS_CACERTFILE` (`go/pkg/k8sinventory/config.go:82`), the Elixir e2e test uses
  `NATS_TEST_CERT_DIR`. These sets can never meet.
- `elixir/serviceradar_core/config/test.exs` reads **fourteen alias pairs** on adjacent lines
  (`SERVICERADAR_TEST_DATABASE_X || SRQL_TEST_DATABASE_X`).

**The failure mode is silence.** Nearly every reader has a default, so a missing value does not
fail — it produces a working connection with the wrong settings. That is the same shape as three
other defects found the same day: a Go↔Rust interop test that skipped inside a passing target, a
manifest drift guard that never ran, and an NTP corpus that compiled to zero fingerprints. In every
case a green signal asserted nothing.

Two structural causes:

1. **No single ground truth.** The readers, `.bazelrc`, and `buildbuddy_setup_fixture_env.sh` each
   define part of the contract; none validates another.
2. **Maximum privilege by default.** `database_env` forwards all 45 names to every database test
   action regardless of need, so NATS material reaches targets that never open a NATS connection.

Because values arrive as ambient process state rather than declared inputs, these tests also cannot
be remotely executed or cached.

## What Changes

Move the contract into git, and make every layer of it mechanically checkable.

- **Schema and configuration as committed data.** A protobuf schema under `config/proto/`, one
  text-format instance per environment under `config/environments/`. The schema defines what exists;
  the instances are the ground truth for values. No secrets.
- **A committed rule set** expressing validation as data over a **closed predicate vocabulary**
  (`required`, `non_empty`, `int_range`, `one_of`, `matches`, `required_if`, `forbidden_value`,
  `equal_across_envs`). Rules are versioned and reviewed like code. Each rule declares a **phase**:
  checkable against the file alone, or only against config resolved together with secrets.
- **Three native managers** — Rust, Go, and Elixir each implement `ConfigManager` and
  `SecretManager` in-language. No FFI, no NIF: protobuf codegen already provides the cross-language
  contract, so adding a foreign-function layer would re-solve a solved problem while importing a
  crash surface and cross-compilation cost.
- **A generated conformance vector file**, committed, consumed by a thin harness per language.
  Vectors assert **violation identity** (code and field path), not merely accept/reject.
- **Least privilege by construction.** Configuration files are Bazel targets, so a target declares
  the config it needs as `data` and physically cannot read the rest. Secrets cannot be build
  targets, so each component instead declares the logical secret names it may request, and the
  provider refuses anything undeclared.
- **One variable at the boundary:** `SERVICERADAR_ENV` ∈ {`localhost`, `ci`, `saas`, `onprem`}. It
  selects the config file and the secret provider. Deployment sets it via Docker or Kubernetes.

Composite values are assembled, never stored. A PostgreSQL DSN is built at runtime from config
fields plus resolved secrets — and the **role name is configuration, not a secret**, because it is
an identity rather than a credential.

## Impact

- **Affected specs:** new capability `unified-configuration`.
- **Affected code:** `.bazelrc`, `buildbuddy.yaml`, `buildbuddy_setup_fixture_env.sh`,
  `rust/integration-db`, `rust/srql`, `integration_tests/srql`, `elixir/serviceradar_core`,
  `elixir/web-ng`, `elixir/serviceradar_core_elx`, `go/pkg/k8sinventory`, `go/pkg/trivysidecar`.
- **Deleted outright:** `buildbuddy_setup_fixture_env.sh` and `scripts/ci/configure-srql-fixture.sh`;
  the `database_env` (37 lines) and `nats_env` (8 lines) profiles; and in Rust `owner_from_url`,
  `repoint_database`, `normalize_sslmode_for_tokio_postgres`, and the `require_verified_tls` guard —
  each of which exists only because a credential and an identity were welded into one string.
- **Survives, and should not be conflated with this change:** a small secret path (~3 logical names
  from a provider) and `--strategy=TestRunner=local`, which is required for the unrelated reason
  that the fixture is a cluster-internal ClusterIP.
- **The `.bazelrc` drift guard must be rebuilt:** `//:buildbuddy_cache_proxy_config_test` asserted
  that specific `--test_env` lines exist in `.bazelrc`. It has been deleted, so removing those
  lines is now silent rather than red — which is worse, not better. A replacement Bazel test
  target is required; see `tasks.md`.
- **Breaking:** every service and test changes how it reads configuration; deployment manifests must
  set `SERVICERADAR_ENV`. Phased migration is mandatory — see `tasks.md`.
- **Non-goal:** this does not change what any setting means, only where it comes from and how it is
  proven correct.
