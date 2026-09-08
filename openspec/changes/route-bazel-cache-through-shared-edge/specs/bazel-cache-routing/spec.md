## ADDED Requirements

### Requirement: Remote Bazel profiles use the authenticated public cache proxy
The repository SHALL route remote-cache traffic inherited through `build:remote_base` to
`grpcs://cache-proxy.carverauto.dev:443` and SHALL preserve
`remote_bytestream_uri_prefix=carverauto.buildbuddy.io`. Remote execution, BES, and results URLs
MUST continue targeting upstream BuildBuddy.

#### Scenario: CI uses the proxy for cache and upstream BuildBuddy for execution
- **GIVEN** the shared public cache-proxy route is healthy
- **AND** the Bazel client has a valid BuildBuddy credential outside source control
- **WHEN** the client builds with `--config=ci`
- **THEN** remote-cache RPCs SHALL use `grpcs://cache-proxy.carverauto.dev:443`
- **AND** remote execution, BES, results links, and bytestream artifact URIs SHALL continue naming
  `carverauto.buildbuddy.io`

#### Scenario: Protected cache RPC rejects an invalid credential
- **GIVEN** the public TLS listener is reachable
- **WHEN** a client attempts a protected ActionCache or CAS operation without a valid BuildBuddy
  credential
- **THEN** the cache proxy SHALL reject that operation through its native BuildBuddy authentication
  path
- **AND** an anonymous Capabilities response SHALL NOT be treated as proof of authorization

### Requirement: Cache-only selection preserves host-native execution
The repository SHALL provide `build:cache_only` for authenticated cache and BES transport without
selecting remote execution or a foreign host/target platform. The profile MUST NOT set a remote
executor, host platform, target platform, `EXECUTOR=remote`, remote JDK/toolchain, or Linux-only
environment.

#### Scenario: Darwin integration build remains native
- **GIVEN** a Darwin workstation has a valid credential in ignored local configuration
- **WHEN** the developer invokes a guarded database test with `--config=cache_only` and local
  `TestRunner`
- **THEN** declared build outputs MAY be read from or written to the authenticated remote cache
- **AND** the test binary and `TestRunner` SHALL execute for the Darwin host
- **AND** no Linux RBE platform SHALL be selected

#### Scenario: Remote base adds execution ownership
- **WHEN** a client selects `build:remote_base` or a profile that inherits it
- **THEN** it SHALL inherit the same cache/BES transport from `build:cache_only`
- **AND** `build:remote_base` alone SHALL add the Linux executor, platforms, toolchains, and
  remote-only environment

#### Scenario: Darwin publishes Linux images through the platform-safe path
- **GIVEN** a Darwin workstation needs to publish Linux/amd64 OCI images
- **WHEN** it invokes the supported publisher
- **THEN** the image graph SHALL build with the Linux CI platform
- **AND** only the generated crane/jq launcher SHALL be replaced with host-native tools
- **AND** no direct image push SHALL use `build:cache_only` as if it selected a Linux target

### Requirement: Canonical Make entry points do not reference removed cache profiles
Canonical and compatibility Make targets SHALL use defined Bazel profiles and shared recipe bodies.
`make test` SHALL retain its canonical workspace scope and integration/acceptance exclusions, and
the ignored `.bazelrc.remote` SHALL carry credentials or local overrides rather than selecting a
removed profile.

#### Scenario: Canonical unit tests retain their scope
- **WHEN** a developer runs `make test`
- **THEN** the canonical optimized CI unit-test sweep SHALL run for `//...`
- **AND** integration and acceptance tests SHALL remain excluded by the canonical filters
- **AND** the inherited cache endpoint SHALL be the authenticated public proxy

#### Scenario: Compatibility aliases remain valid
- **WHEN** a developer runs `make test-cache` or `make build-workspace-cache`
- **THEN** the alias SHALL reuse its corresponding canonical recipe and scope
- **AND** it SHALL NOT reference an undefined or retired `build:cache_proxy` profile

### Requirement: Core integration tests use explicit Bazel fixture targets safely
The repository SHALL expose the guarded lifecycle as explicit Bazel targets invoked in the order
`sweep -> prepare -> conditional migrate -> provision -> suite -> teardown`. Database-facing test
actions SHALL use the local `TestRunner`, while eligible compile/dependency actions MAY read from
and write to the authenticated remote cache. The caller SHALL use canonical base `SRQL_TEST_*`
URLs, one unique numeric run identity for the sequence, and an explicit teardown after
provisioning. Database test results MUST NOT be cached. Workstation NodePort clients SHALL retain
TLS hostname verification for both Rust and Elixir database clients.

Database and NATS credential variables SHALL be forwarded only by explicit integration-test
profiles. Generic remote unit-test invocations MUST NOT receive those values in their action
environment or remote cache metadata.

The unsuffixed core integration suite and the named SRQL fixture suites SHALL use the same
shared-fixture compatibility guard as their lifecycle and shard targets, so no explicit fixture
entry point can run or pass vacuously without caller opt-in.

#### Scenario: Shared-fixture entry points fail closed
- **GIVEN** the caller has not supplied `--//build:enable_integration_tests`
- **WHEN** it explicitly names the unsuffixed core integration suite or either named SRQL fixture
  suite
- **THEN** the target SHALL be incompatible rather than running DDL or passing with zero tests
- **AND** an opted-in invocation of either named SRQL fixture suite SHALL explicitly admit its
  `manual` tag

#### Scenario: Developer executes the guarded lifecycle
- **GIVEN** canonical fixture and admin URLs and one numeric run identity are available
- **WHEN** the developer invokes the lifecycle targets in order
- **THEN** every lifecycle target SHALL receive `--//build:enable_integration_tests`
- **AND** test invocations SHALL clear manual tag filters, select local `TestRunner`, and disable
  test-result caching
- **AND** prepare SHALL clear the manual build filter and migration SHALL run only when reported
  pending
- **AND** the base fixture URL SHALL remain in `SRQL_TEST_DATABASE_URL`, not the final
  `SERVICERADAR_TEST_DATABASE_URL` override

#### Scenario: CI workflows keep database actions on fixture-reachable runners
- **WHEN** Forgejo or BuildBuddy invokes the core database lifecycle
- **THEN** database-facing TestRunner actions SHALL execute locally on that workflow runner
- **AND** eligible compile/dependency actions SHALL remain remote and cache-eligible
- **AND** mutable database test results SHALL neither be cached nor uploaded
- **AND** each workflow SHALL establish one unique numeric run identity for the sequence
- **AND** Forgejo and BuildBuddy SHALL each run the two named SRQL fixture suites under the same
  local, non-cached, non-uploaded policy

#### Scenario: Dedicated database workflow fails closed without fixture credentials
- **GIVEN** the Forgejo database-integration workflow has been selected
- **WHEN** either fixture DSN or the fixture CA is unavailable
- **THEN** the workflow SHALL fail before fixture setup or database lifecycle execution
- **AND** it SHALL NOT report success by conditionally skipping the database suites

#### Scenario: Generic remote tests do not receive fixture credentials
- **GIVEN** fixture and NATS credentials exist in the Bazel client's environment
- **WHEN** the ordinary remote unit-test sweep runs without an integration environment profile
- **THEN** its TestRunner actions SHALL NOT receive database DSNs, database TLS keys, NATS URLs, or
  NATS key material
- **AND** guarded database invocations SHALL explicitly select `database_env`

#### Scenario: Developer selects one shard
- **GIVEN** the developer will run `//elixir/serviceradar_core:integration_tests_s0`
- **WHEN** the provision step runs
- **THEN** `//rust/integration-db:provision_db_s0` SHALL create only the matching `s0` database
- **AND** equivalent focused provision targets SHALL exist for `s1` through `s7`
- **AND** the unsuffixed provision target SHALL remain available for the full eight-shard CI suite

#### Scenario: Cache-only run can populate compile artifacts
- **GIVEN** a workstation has a valid ignored BuildBuddy credential
- **WHEN** the developer selects `--config=cache_only` for the local lifecycle
- **THEN** the test result SHALL not be cached
- **AND** the invocation SHALL NOT broadly disable uploading locally executed action results,
  because locally compiled misses must remain eligible to populate the shared cache

#### Scenario: Workstation verifies the fixture certificate through a NodePort
- **GIVEN** the fixture service exposes a reachable NodePort on a cluster node
- **WHEN** the caller supplies the fixture service DNS name separately from the NodePort IP
- **THEN** `PGSSLSERVERNAME` SHALL carry that name to the Rust lifecycle client
- **AND** `SRQL_TEST_DATABASE_SERVER_NAME` SHALL carry that name to the Elixir client
- **AND** both variables SHALL reach Bazel test actions through checked-in test environment
  forwarding
- **AND** the shared DSN MAY retain libpq `verify-ca` or `verify-full` semantics while the Rust
  lifecycle normalizes that value only for `tokio-postgres` parsing and continues certificate and
  hostname verification through its rustls connector

#### Scenario: Pre-set workflow DSNs omit an SSL mode
- **GIVEN** BuildBuddy supplies credential-bearing fixture DSNs and a fixture CA
- **AND** either DSN omits or weakens `sslmode`
- **WHEN** credential setup materializes the per-run environment file
- **THEN** both DSNs SHALL contain `sslmode=verify-full`
- **AND** Rust SHALL require TLS and verify through rustls
- **AND** Elixir SHALL use peer and hostname verification

#### Scenario: Red shard is followed by teardown
- **GIVEN** the caller has successfully provisioned a disposable run prefix
- **WHEN** the focused or full suite fails
- **THEN** the caller SHALL invoke `//rust/integration-db:teardown_db` for that same run identity
- **AND** Forgejo SHALL retain an `always()` teardown step
- **AND** BuildBuddy SHALL retain a same-shell EXIT trap that fails an otherwise-green step when
  teardown fails
- **AND** a later stale sweep SHALL remain the backstop for a killed host that cannot run cleanup

#### Scenario: Stale sweep evaluates each disposable database independently
- **GIVEN** cancelled runs left disposable databases at different ages
- **WHEN** the stale sweep evaluates its age threshold
- **THEN** it SHALL inspect each pg_default database's own OID-derived `PG_VERSION` marker mtime
- **AND** it SHALL NOT classify all candidates from the shared `pg_database` relation timestamp
- **AND** it SHALL skip rather than force-disconnect a candidate that still has active sessions

#### Scenario: Credential material is removed after a workflow run
- **WHEN** fixture setup writes a credential-bearing environment file
- **THEN** the file SHALL have a unique per-run path and mode 0600
- **AND** success, test failure, and setup failure paths SHALL remove that exact file
- **AND** a cleanup failure SHALL fail an otherwise-successful workflow or local lifecycle

### Requirement: Public ingress preserves a private backend and source-controlled secret hygiene
The public cache-proxy route SHALL terminate TLS at the shared gateway while the cache-proxy Service
remains `ClusterIP`, and no BuildBuddy client credential, proxy upstream key, database credential,
or TLS private key SHALL be committed to this repository.

#### Scenario: Gateway removal does not interrupt executor cache traffic
- **GIVEN** executors use the cache-proxy Service FQDN directly
- **WHEN** the public gateway route is disabled and client cache endpoints are rolled back upstream
- **THEN** executors SHALL continue using the internal cache-proxy path
- **AND** remote execution and BES SHALL remain on upstream BuildBuddy

#### Scenario: Repository configuration contains no authentication secret
- **WHEN** the public endpoint, Bazel profiles, and integration lifecycle are reviewed
- **THEN** the repository SHALL contain endpoint and routing configuration only
- **AND** BuildBuddy, database, and TLS credentials SHALL remain in ignored files, runner
  configuration, or Kubernetes Secrets
