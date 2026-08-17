# Tasks

Ordered by blast radius, smallest first. **Do not collapse phases.** The inventory note documents
three cases where a static read-scan missed a live consumer — a `bazel run` target inheriting the
ambient environment, a test asserting on `.bazelrc`, and a value read under a different spelling.

## 1. Settle the open decisions

- [x] Confirm the environment set — **kinds are `localhost`, `ci`, `saas`, `onprem`, but on-prem is
      multi-instance**, so identity is `(kind, instance)` encoded as `<kind>[:<instance>]`
      (e.g. `onprem:united`). See design.md Decision 7
- [x] Verify whether a mature CEL implementation exists for Elixir — **no** (2026-08-17).
      protovalidate supports Go/JS/TS/Java/Python/C++ only; the sole BEAM-reachable CEL is `cel`
      v0.3.1 (Gleam), last released 2024-12-19, 532 downloads all time, 0 in the last 7 days.
      The closed predicate vocabulary is adopted; see design.md Decision 3
- [x] Decide whether `.textproto` instances are committed or generated — **committed, always in git**
- [x] Identify which values must exist before the Elixir application tree starts — **all of them**.
      The Elixir manager must therefore be callable from `config/runtime.exs`; see Decision 9
- [x] Decide where on-prem customer instance files live — **in this repository**, at
      `config/environments/onprem/<id>.textproto`, per Decision 10 (everything in one `config/`
      tree). Keeps the completeness meta-rule in this repo's build rather than a pipeline it does
      not control
- [x] Decide the source-tree layout — **one `config/` tree** holding schema, instances, rule set,
      fixtures, vectors, formal model and all three implementations; see design.md Decision 10
- [x] Decide the relationship to the existing config machinery — **the bootstrap layers are rebuilt
      on the managers**; see design.md Decision 11

## 2. Schema

- [ ] Add `config/proto/config.proto` covering database, NATS, TLS and pool settings
- [ ] Enumerate every schema-covered setting from `openspec/notes/env-var-inventory.md` §6
- [ ] Use explicit presence (`optional`) on every field that must be supplied
- [ ] Reserve `0` as `*_UNSPECIFIED` in every enum
- [ ] Model TLS mode as an enum; model connecting role and owning role as separate fields
- [ ] Wire codegen for Rust (prost), Go, and Elixir

## 3. Rule set and predicate specification

- [ ] Define the closed predicate vocabulary and its formal semantics, including totality
- [ ] Specify engine semantics: cascading, short-circuit vs exhaustive, violation ordering,
      phase interaction (design.md, Decision 4)
- [ ] Model the engine (TLA+/Alloy) against those semantics
- [ ] Define the rule-set file format: `(field_path, predicate, params, phase, code)`
- [ ] Author the initial rule set covering every schema field
- [ ] Implement the meta-rule: every schema field carries at least one rule
- [ ] Author one violating fixture per rule

## 4. Configuration files

- [ ] Add `config/environments/{localhost,ci,saas}.textproto`
- [ ] Add `config/environments/onprem/<id>.textproto` per deployment, in this repository
- [ ] Expose each as a Bazel target at the granularity components consume (database, NATS, TLS)
- [ ] Add the build-time validator as a Bazel test over file-phase rules, iterating **every**
      instance including each on-prem one
- [ ] Add the credential-shape check that rejects secrets in configuration files
- [ ] Add the Bazel rule that compiles each committed `.textproto` to binary via `protoc --encode`,
      exposing one target per instance
- [ ] Add the round-trip test asserting each generated binary matches its committed `.textproto`
- [ ] Ship the compiled binary inside release artifacts — for Elixir, into an app's `priv/`, read at
      boot with `Application.app_dir/2`; never `__DIR__` (see Decision 9)

## 5. Conformance vectors and property tests

- [ ] Generate the conformance vector file from the predicate specification
- [ ] Include violation identity (code, field path) in every vector, not just accept/reject
- [ ] Include the negative fixtures from phase 3 as vectors
- [ ] Implement the thin vector harness in Rust, Go, and Elixir
- [ ] Implement property-based tests per predicate law (proptest, rapid/gopter, StreamData)
- [ ] Confirm all suites are untagged and selected by `make test`

## 6. Managers

- [ ] Implement `ConfigManager` natively in Rust, Go, and Elixir, keyed by `SERVICERADAR_ENV`
- [ ] Implement `SecretManager` with providers: localhost file, CI store, Kubernetes/OpenBao
- [ ] Implement per-component declared secret manifests; provider refuses undeclared names
- [ ] Hard-error on unset/unrecognised `SERVICERADAR_ENV`, listing the valid set
- [ ] Hard-error on unresolvable secret, naming logical key and provider
- [ ] Implement startup resolution of everything a component declares
- [ ] Implement DSN assembly from typed fields plus resolved secrets
- [ ] Implement the `explain` command with provenance and redaction

## 7. Refactor every known call site onto the managers

Every direct environment read below is replaced by a `ConfigManager` / `SecretManager` call in that
file's own language. The list is the complete set of readers measured in
`openspec/notes/env-var-inventory.md` §6; a file is done when it contains no `env::var`,
`System.get_env`, or `os.Getenv` for a schema-covered name.

**Exit criterion for the whole phase:** an automated check fails the build if any of these
retrieval calls reappears for a schema-covered variable.

### 7a. Rust — fixture lifecycle first (smallest blast radius)

- [ ] `rust/integration-db/src/lib.rs` — 9 reads: `SRQL_TEST_DATABASE_URL`, `SRQL_TEST_ADMIN_URL`,
      `SERVICERADAR_TEST_ADMIN_URL`, `SERVICERADAR_TEST_DATABASE_OWNER`,
      `SRQL_TEST_DATABASE_CA_CERT`, `PGSSLROOTCERT`, `PGSSLSERVERNAME`, `GITHUB_RUN_ID`,
      `GITHUB_RUN_ATTEMPT`
- [ ] Delete `owner_from_url`, `repoint_database`, `normalize_sslmode_for_tokio_postgres`
- [ ] Delete `require_verified_tls` once TLS mode is typed end to end
- [ ] `rust/integration-db/tests/provision_db_test.rs` — `SERVICERADAR_TEST_DB_SHARDS`
- [ ] `rust/integration-db/src/bin/prepare_template.rs` — resolves through `db::` accessors; confirm
      no ambient reads remain (note: `bazel run`, so it inherits the client environment)
- [ ] `integration_tests/srql/tests/support/harness.rs` — 11 reads incl. `PGSSLTARGETNAME`,
      `SRQL_FIXTURE_ROOT`, `SRQL_TEST_DATABASE_TLS_SERVER_NAME` (none currently forwarded)
- [ ] `rust/srql/src/config.rs` — `PGSSLROOTCERT`, `PGSSLSERVERNAME`, `PGSSLCERT`, `PGSSLKEY`,
      `PGSSLTARGETNAME`

### 7b. Elixir — test configuration

- [ ] `elixir/serviceradar_core/config/test.exs` — ~35 reads; collapse the **fourteen alias pairs**
      (`SERVICERADAR_TEST_DATABASE_X || SRQL_TEST_DATABASE_X` on adjacent lines 57-180)
- [ ] `elixir/serviceradar_core/test/db/integration_env.exs` — incl. `URI.parse` of the DSN to
      derive the per-shard database name; replace with a computed field
- [ ] `elixir/serviceradar_core/test/db/template_env.exs`
- [ ] `elixir/serviceradar_core/test/serviceradar/cluster/database_bootstrap_integration_test.exs`
      — ~32 reads, the largest single call site
- [ ] `build/elixir_tests.bzl` — pins `SRQL_TEST_DATABASE_URL` / `SERVICERADAR_TEST_DATABASE_URL`
      and their `_FILE` variants to `""`; remove once nothing reads them

### 7c. Elixir — application configuration

- [ ] `elixir/serviceradar_core/config/{dev,runtime}.exs`
- [ ] `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex` — `CNPG_*` incl.
      `CNPG_ADMIN_USERNAME` / `CNPG_ADMIN_PASSWORD` (sole readers) and `CNPG_APP_USER` /
      `CNPG_APP_PASSWORD`
- [ ] `elixir/serviceradar_core_elx/config/runtime.exs`
- [ ] `elixir/web-ng/config/{dev,runtime,test}.exs` — incl. the five `TEST_CNPG_*` (sole readers)
- [ ] `elixir/serviceradar_agent_gateway/config/runtime.exs` — `NATS_URL`

### 7d. Go

- [ ] `go/pkg/k8sinventory/config.go:82-85` — `NATS_CACERTFILE`, `NATS_CERTFILE`, `NATS_KEYFILE`,
      `NATS_SERVER_NAME`
- [ ] `go/pkg/trivysidecar/config.go:64-67` — same four
- [ ] Reconcile the naming drift: `.bazelrc` forwards `NATS_CA_FILE`; Go reads `NATS_CACERTFILE`
- [ ] Reconcile the `NATS_TEST_*` family used by
      `test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs`

### 7e. Rebuild the bootstrap layers on the managers

- [ ] Survey the `CORE_*` family into the schema — `CORE_SEC_MODE`, `CORE_CERT_FILE`,
      `CORE_KEY_FILE`, `CORE_CA_FILE` (`go/pkg/config/bootstrap/core_client.go`), plus any other
      environment reads in `go/pkg/config/{config,env_loader,file_loader}.go`
- [ ] Re-found `rust/config-bootstrap` on `ConfigManager` / `SecretManager`; remove its own
      environment reads
- [ ] Re-found `go/pkg/config/bootstrap` likewise
- [ ] Add `elixir/config/bootstrap` so all three trees have the same two-layer shape
- [ ] Confirm existing consumers are unaffected at their call sites: `rust/log-collector`,
      `rust/flow-collector`, `rust/rperf-client`, `go/cmd/data-services`, `go/cmd/faker`
- [ ] Delete the hand-maintained Rust/Go parity in favour of the shared vectors

### 7f. Build graph

- [ ] Declare configuration targets as `data` on every affected test target
- [ ] Add per-component declared secret manifests
- [ ] Verify the database step end to end on BuildBuddy

## 8. Retire the old machinery

- [ ] Delete `buildbuddy_setup_fixture_env.sh` and its `buildbuddy.yaml` step
- [ ] Delete `scripts/ci/configure-srql-fixture.sh` with the Forgejo tier
- [ ] Reduce `.bazelrc` `database_env` to secrets only; delete `nats_env` if it empties
- [ ] Update `//:buildbuddy_cache_proxy_config_test`, which asserts specific `--test_env` lines
      (`buildbuddy_cache_proxy_config_test.py:216`) — removing them without this reds `make test`
- [ ] Extend that test with the missing direction: every forwarded name must be read, and every name
      the suites read must be forwarded or declared
- [ ] Update `AGENTS.md` and the `srql-fixtures-db-tests` skill

## 9. Deployment

- [ ] Set `SERVICERADAR_ENV` in Docker Compose, Helm, and Kubernetes manifests
- [ ] Add CODEOWNERS on the rule set and the schema
- [ ] Confirm the demo namespace boots on the new path
- [ ] Document the `localhost` developer workflow in `docs/docs/`
