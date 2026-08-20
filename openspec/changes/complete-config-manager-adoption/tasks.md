# Tasks

Carried over from `add-unified-config-and-secret-managers` (archived), which delivered the
capability. These are the adoption phases, kept in their original numbering so the two documents
line up. Ordered by blast radius, smallest first. **Do not collapse phases.**

Read `openspec/changes/archive/*-add-unified-config-and-secret-managers/design.md` before starting:
Decisions 6, 9, 10, 11 and 12 govern everything below. `config/README.md` is the practical guide.

**Exit criterion for phase 7:** an automated check fails the build if `env::var`,
`System.get_env` or `os.Getenv` reappears for a schema-covered name.

## 1. Go SecretManager -- the prerequisite for everything in 7d

- [ ] Port `EnvProvider` + `EnvironmentProvider` to `config/manager_secret/go`, with the same name
      transform (`database.password` -> `SERVICERADAR_SECRET_DATABASE_PASSWORD`; `.`, `-`, `/`
      become `_`, ASCII upcase) and the same "empty variable is absent, not an empty credential"
      rule as Rust and Elixir
- [ ] Add the logical-name constants mirroring Rust's `secrets.rs` and Elixir's
      `ServiceradarSecret.Names`
- [ ] Cover it with the same cases as `config/manager_secret/rust/tests/traits/` -- the transform
      is the contract every `--test_env` list is derived from, so a divergence is silent

## 2. Elixir -- test configuration (7b remainder)

Read `elixir-inventory.md` in the archived change first: 63 usage-proven alias pairs collapse
first, which is a pure Elixir edit, and section 3.1 is the argument for the whole change -- 350
names are set by nothing in this repository, and when absent six raise while 340 silently change
behaviour.

- [ ] `elixir/serviceradar_core/config/test.exs` -- ~35 reads; collapse the **fourteen alias pairs**
      (`SERVICERADAR_TEST_DATABASE_X || SRQL_TEST_DATABASE_X` on adjacent lines 57-180)
- [ ] `elixir/serviceradar_core/test/db/integration_env.exs` -- incl. `URI.parse` of the DSN to
      derive the per-shard database name; replace with a computed field. Use
      `test/db/fixture_config.exs`, which `template_env.exs` already resolves through
- [ ] `elixir/serviceradar_core/test/serviceradar/cluster/database_bootstrap_integration_test.exs`
      -- ~32 reads, the largest single call site
- [ ] `elixir/serviceradar_core/test/test_helper.exs` and
      `elixir/serviceradar_agent_gateway/test/test_helper.exs` -- they use `SRQL_TEST_DATABASE_URL`
      / `_FILE` only as a PRESENCE PROBE ("is a database configured?"), never to extract
      coordinates. Post-migration the question is structural: `SERVICERADAR_ENV` names an
      environment whose instance either has a `database` section or does not
- [ ] `build/elixir_tests.bzl` -- pins `SRQL_TEST_DATABASE_URL` / `SERVICERADAR_TEST_DATABASE_URL`
      and their `_FILE` variants to `""`; remove once nothing reads them

## 3. Elixir -- application configuration (7c)

Higher risk than phase 2: these decide how shipped services boot.

- [ ] `elixir/serviceradar_core/config/{dev,runtime}.exs`
- [ ] `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex` -- `CNPG_*` incl.
      `CNPG_ADMIN_USERNAME` / `CNPG_ADMIN_PASSWORD` (sole readers) and `CNPG_APP_USER` /
      `CNPG_APP_PASSWORD`
- [ ] `elixir/serviceradar_core_elx/config/runtime.exs`
- [ ] `elixir/web-ng/config/{dev,runtime,test}.exs` -- incl. the five `TEST_CNPG_*` (sole readers)
- [ ] `elixir/serviceradar_agent_gateway/config/runtime.exs` -- `NATS_URL`

## 4. Go (7d)

**Measured scope (`go-inventory.md` in the archived change).** 246 read sites, 173 distinct names
-- about a quarter of the Elixir surface. 77 of those names are read only by `build/`, `tools/`
and `_test.go` files and must NOT acquire schema fields, leaving 91 names in shipped services, 11
of them credentials.

- [ ] **Delete `EnvConfigLoader`** (`go/pkg/config/env_loader.go` plus the `configSourceEnv` branch
      in `go/pkg/config/config.go`). It derives env names from JSON struct tags by reflection and
      accepts a whole config document through `SERVICERADAR_CONFIG_JSON`, so no scan can enumerate
      it. Every chart already sets `CONFIG_SOURCE=file`; it is dead in deployment and live in code
- [ ] **Rename `NATS_CREDSFILE` to `NATS_CREDS_FILE`** in `go/pkg/k8sinventory/config.go:81` and
      `go/pkg/trivysidecar/config.go:63`. Nothing sets the no-underscore spelling; Helm and Elixir
      both use `NATS_CREDS_FILE`. Not an outage today (both workloads use mTLS and set no creds
      file), but the value cannot be supplied from the chart as written
- [ ] **Require `os.LookupEnv` in the gate.** Zero of the 169 literal-name reads use it, so no Go
      code can currently distinguish an unset variable from an empty one
- [ ] `go/pkg/k8sinventory/config.go:82-85` -- `NATS_CACERTFILE`, `NATS_CERTFILE`, `NATS_KEYFILE`,
      `NATS_SERVER_NAME`
- [ ] `go/pkg/trivysidecar/config.go:64-67` -- same four
- [ ] Reconcile the naming drift: `.bazelrc` forwards `NATS_CA_FILE`; Go reads `NATS_CACERTFILE`
- [ ] Reconcile the `NATS_TEST_*` family used by
      `test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs`

## 5. Rebuild the bootstrap layers on the managers (7e)

- [ ] Survey the `CORE_*` family into the schema -- `CORE_SEC_MODE`, `CORE_CERT_FILE`,
      `CORE_KEY_FILE`, `CORE_CA_FILE` (`go/pkg/config/bootstrap/core_client.go`), plus any other
      environment reads in `go/pkg/config/{config,env_loader,file_loader}.go`
- [ ] Re-found `rust/config-bootstrap` on `ConfigManager` / `SecretManager`; remove its own
      environment reads
- [ ] Re-found `go/pkg/config/bootstrap` likewise
- [ ] Add `elixir/config/bootstrap` so all three trees have the same two-layer shape
- [ ] Confirm existing consumers are unaffected at their call sites: `rust/log-collector`,
      `rust/flow-collector`, `rust/rperf-client`, `go/cmd/data-services`, `go/cmd/faker`
- [ ] Delete the hand-maintained Rust/Go parity in favour of the shared vectors

## 6. Build graph (7f)

- [ ] Declare configuration targets as `data` on every affected test target
- [ ] Add per-component declared secret manifests
- [ ] Verify the database step end to end on BuildBuddy

## 7. Retire the old machinery (8)

Only after phases 2-4: each of these is load-bearing until its last reader is converted.

- [ ] Delete `buildbuddy_setup_fixture_env.sh` and its `buildbuddy.yaml` step
- [ ] Delete `scripts/ci/configure-srql-fixture.sh` with the Forgejo tier
- [ ] Reduce `.bazelrc` `database_env` to secrets only; delete `nats_env` if it empties
- [ ] Update `AGENTS.md`, `config/README.md` section 10, and the `srql-fixtures-db-tests` skill

## 8. Deployment (9)

- [ ] Set `SERVICERADAR_ENV` in Docker Compose, Helm, and Kubernetes manifests
- [ ] Mount the compiled instance for the deployed kinds at `/etc/serviceradar/environment.binpb`,
      and ship it inside release artifacts -- for Elixir into an app's `priv/`, read with
      `Application.app_dir/2`, never `__DIR__` (Decision 9). Nothing mounts it today, so `saas`,
      `demo` and `onprem` currently have no instance to load
- [ ] Add CODEOWNERS on the rule set and the schema
- [ ] Confirm the demo namespace boots on the new path
- [ ] Document the `localhost` developer workflow in `docs/docs/`

## 9. Assurance (carried from section 3 of the parent)

- [ ] Model the engine (TLA+/Alloy) against `config/SEMANTICS.md`. Additive: the three
      implementations are already pinned to those semantics by shared vectors and property tests
