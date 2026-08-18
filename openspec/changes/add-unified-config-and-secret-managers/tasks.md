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

- [x] Add `config/proto/config.proto` covering database, NATS, core, TLS and pool settings
- [x] Enumerate the schema-covered settings from `openspec/notes/env-var-inventory.md` §6, plus the
      `CORE_*` family required by Decision 11 (11 variables surveyed:
      `CORE_{ADDRESS,API_URL,SEC_MODE,SERVER_NAME,TRUST_DOMAIN,SERVER_SPIFFE_ID,WORKLOAD_SOCKET}`;
      `CORE_{CERT_FILE,KEY_FILE,CA_FILE,CERT_DIR}` deliberately excluded as secret material)
- [x] Use explicit presence (`optional`) on every field
- [x] Reserve `0` as `*_UNSPECIFIED` in every enum
- [x] Model TLS mode as an enum; model connecting role and owning role as separate fields
- [x] Add `DgraphConfig` (host, port, tls_mode) for `rust/dgraph-client`, with a SEPARATE
      `DgraphTlsMode` enum. Not a reuse of `TlsMode`: the Dgraph client has no verify-full, so
      a shared enum would let an instance state `TLS_MODE_VERIFY_FULL` for Dgraph — a setting
      that reads as the strongest option and that no client can honour. One host rather than a
      repeated endpoint list, because in Kubernetes the alpha Service already load-balances;
      ACL username/password/api key/bearer token/namespace are omitted (the last four are
      SecretManager's, and the schema does not carry fields no instance sets)
- [x] Wire Go codegen (`//config/proto:configpb`) — builds on RBE
- [x] Wire Rust codegen (prost) — `//config/rust:config_schema`, crate
      `serviceradar-config-schema`. Registered in the workspace `members` and `Cargo.lock`.
      Three tests pass on RBE, including `unset_fields_are_absent_not_defaulted`, which proves
      explicit presence survives prost codegen (`Option`, not a zero value)
- [x] Wire Elixir codegen — Bazel `elixir_proto_library` (`//config/proto:config_ex`), with
      `binding_drift_{config,rules}_test` as the drift guard against the checked-in
      `config/proto_bindings/elixir/**/{config,rules}.pb.ex` (`Serviceradar.Config.V1.*`).
      Every optional field carries `proto3_optional: true`, so presence survives on the Elixir
      side too
- [x] Wire the Go drift guard — `//config/proto:config_go` regenerates the checked-in
      `config/proto_bindings/go/{config,rules}.pb.go`, and
      `binding_drift_go_{config,rules}_test` compares them. The Go BUILD file claimed a
      `make verify-proto-go-config` guard that **was never written**, so the checked-in Go
      bindings had no drift check at all while the Elixir ones did
- [x] Decide where per-target values live that are NOT per-environment
      (`SERVICERADAR_TEST_DB_SHARDS` is correctly a target `env` attribute today; `SRQL_FIXTURE_ROOT`
      is still unplaced)
      DECIDED, by what a value VARIES WITH. EnvironmentConfig holds what varies by
      environment -- all four kinds, localhost and ci included. A value that varies by
      BUILD or CHECKOUT rather than by environment is not environment configuration, and
      Bazel already models it as a declared input.
      `SRQL_FIXTURE_ROOT` was a path to test data inside the build tree. It does not differ
      between ci and saas; it differs between two checkouts of the same environment, which is
      precisely the ambient-state dependency this system exists to remove. It is DELETED from
      `integration_tests/srql/tests/support/harness.rs` rather than relocated: no schema
      field, and no environment override either. Fixture data is a declared input, resolved
      through runfiles.

      That is the general rule. A value either comes from the configuration system or from a
      declared build input. Nothing gets an ad-hoc environment override in a script or a
      test -- an override that can repoint an input is how a run ends up reading something
      the build graph does not know about, and it is what makes a green result meaningless.

## 3. Rule set and predicate specification

- [x] Define the closed predicate vocabulary and its formal semantics, including totality —
      `config/SEMANTICS.md` sections 2-3; nine predicates, verdict is
      `Satisfied | Violated | NotApplicable`, every predicate pure and total
- [x] Specify engine semantics — `config/SEMANTICS.md` sections 4-6: cascading (an absent
      required field yields exactly one violation), exhaustive evaluation, total ordering by
      `(field_path, code)`, and phase/scope gating that skips rather than returns NotApplicable
- [ ] Model the engine (TLA+/Alloy) against those semantics
- [x] Define the rule-set file format — `config/proto/rules.proto`; the predicate is a `oneof`
      so a predicate and its parameters cannot disagree
- [x] Extend the vocabulary with `ForbiddenIf` — a field must be ABSENT when another holds one
      of the given values. It closes the half of `instance` that had no predicate: the schema said
      "required if and only if ONPREM", but only the required half was enforceable, so nothing
      stopped `ci.textproto` naming an instance. Its trigger is a SET where `RequiredIf` takes a
      single value, because the forbidding side enumerates the COMPLEMENT of what is permitted and
      a per-value rule is how a newly added enum value becomes permitted by omission.
      Guarded by `a_conditional_pair_keyed_on_an_enum_is_exhaustive`: a `RequiredIf`/`ForbiddenIf`
      pair keyed on the same enum must cover every value of it. **Both negative controls verified
      on RBE** — naming an instance on `ci` yields `INSTANCE_FORBIDDEN_OUTSIDE_ONPREM`, and adding
      a sixth kind without extending the trigger set fails naming the uncovered value. The plain
      coverage check could not catch the latter: the field still has rules
- [x] Author the initial rule set covering every schema field — `config/rules/ruleset.textproto`,
      **37 rules**, compiles to a 3234-byte binary. Negative controls verified on RBE: an unknown
      predicate and an unknown enum in `scope` each fail the build
- [x] Implement the meta-rule: every schema field carries at least one rule —
      `//config/validator:meta_rule_test`, over `//config/proto:config_descriptor_set`. The field
      list comes from the schema's OWN DESCRIPTOR, recursed to leaves, not from a list in the test:
      a hand-kept list is one more thing to forget to update, and forgetting is the failure being
      caught. Also checks the reverse — a rule naming a field the schema lacks is dead, since it
      can never fire — and that the walk reaches nested sections, because a walk returning only
      top-level fields would pass while constraining nothing.
      **Negative control verified on RBE:** adding `dgraph.forgotten_field` to the schema without a
      rule fails with `schema fields with no rule -- they are unvalidated, which reads exactly like
      valid: ["dgraph.forgotten_field"]`. That is precisely the mistake this session came close to:
      four `dgraph.*` fields were added by hand and nothing would have caught a missing rule
- [x] Define the fixture format and author representative fixtures —
      `config/rules/fixtures/fixtures.textproto`, **10 cases** covering every predicate kind plus
      cascading, ordering, and both sides of scope. Fixtures and conformance vectors are the same
      artifact, so a rule cannot gain one without the other
- [x] Generate the per-rule fixture covering all rules — **47 fixtures, all 45 rules exercised**.
      Generated SHAPE, authored INTENT: each case is one mutation of a valid baseline, and its
      expected violations are written by hand from what the rule is FOR, never read back from the
      engine — which would make the comparison circular and prove nothing. All 35 hand-written
      expectations matched the engine on the first run

## 4. Configuration files

- [x] Add `config/environments/ci.textproto` (first consumer: the fixture lifecycle)
- [x] Add `config/environments/{localhost,saas}.textproto`
- [x] Add `config/environments/demo.textproto` and `ENVIRONMENT_KIND_DEMO`. A kind rather than
      a saas instance: its own topology, its own admission policy, and every rule scoped
      `except_kinds: LOCALHOST` must reach it
- [x] Add `config/environments/onprem/<id>.textproto` per deployment, in this repository —
      first instance `onprem/untd.textproto`, `instance: "untd"`. Its own Bazel package so each
      deployment's targets mirror its file path and the set grows without touching a shared
      BUILD file. Coordinates are the chart DEFAULTS, since an on-prem install runs the same
      chart; anything a deployment overrides in its values file must be overridden here too.
      **Negative control verified on RBE:** weakening its `database.tls_mode` to `DISABLE` fails
      `file_phase_test` with `onprem/untd.textproto has 1 violation(s):
      database.tls_mode DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST` — a customer instance is
      held to the same cross-environment invariants as ci and saas, which is the whole point of
      Decision 10.
      `INSTANCES` now lives once in `src/utils_tests.rs` and is shared by all three
      instance-wide checks; it was duplicated in `file_phase_test.rs`, which is how an instance
      gets added to one check and not the others
- [x] Expose each as a Bazel target at the granularity components consume — four sections
      (`database`, `nats`, `core`, `dgraph`) per instance, e.g. `//config/environments:ci_database`,
      cut by `//config/tools:extract_section`. This is Decision 6 (least privilege), not caching:
      a target that declares one section PHYSICALLY CANNOT SEE the others, because they are not in
      its runfiles — absolute under remote execution, where only declared inputs reach the executor.
      `//config/validator:section_privilege_test` declares exactly one section and asserts both
      halves. **Negative control verified on RBE:** granting it `ci_binpb` and `ci_nats` makes both
      absence assertions fail, naming the reachable file.
      A tool rather than a protoc invocation because text format cannot be sliced — the section
      boundary is structure, and recovering it from source text would be a parser pretending to be
      a grep. An absent section is an error, not an empty file: zero bytes decode to a message whose
      every field is absent, which validation would report as a dozen missing values rather than as
      the one thing actually wrong
- [x] Add the build-time validator as a Bazel test over file-phase rules, iterating **every**
      instance including each on-prem one
- [x] Add the credential-shape check that rejects secrets in configuration files —
      `//config/validator:credential_shape_test`. Four shapes (URL userinfo, `password=`-style
      connection parameters, PEM material, whole-value base64 runs) plus credential-denoting
      field names. **Verified end to end on RBE:** a DSN with an embedded password planted in
      `demo.textproto` fails the test naming `demo: database.host`.
      Two choices are load-bearing. It scans the CANONICAL TEXT OF THE COMPILED BINARY, not the
      source: that covers every field that is present, including ones no checker knows by name,
      and it does not flag the word "password" in the comment warning against them. And it
      matches on SHAPE, not on a list of bad field names, which would only catch what someone
      already thought of. A false-positive control asserts the values the schema really holds
      (SPIFFE IDs, DSN-less URLs, `platform, ag_catalog`) survive it — a shape check that
      blocks legitimate values gets disabled by whoever it blocks
- [x] Add the Bazel rule compiling each committed `.textproto` to binary via `protoc --encode`
      (`//config:defs.bzl` `environment_config`), one target per instance.
      **Verified on RBE:** `ci.textproto` -> 314-byte binary, and three negative controls each
      fail the build: unknown field (names `not_a_real_field`), wrong type for `port`, and an
      invalid enum value (names `TLS_MODE_BOGUS`)
- [x] Add the round-trip test asserting each generated binary matches its committed `.textproto`
      — `//config/validator:round_trip_test`. Both sides are flattened to `path=value` pairs and
      compared structurally, because the committed file carries comments and blank lines no
      encoder emits, and neither prost nor Elixir's `:protobuf` can parse text format.
      Its weight comes from the two sides being READ FROM DIFFERENT PLACES — source tree vs.
      decoded artifact — so it becomes load-bearing when the binary is copied into a release
      artifact's `priv/` rather than read out of bazel-bin. Within one build the two cannot
      diverge, so the in-test negative control (corrupt one side, confirm the comparison
      notices) is what proves the comparison works
- [ ] Ship the compiled binary inside release artifacts — for Elixir, into an app's `priv/`, read at
      boot with `Application.app_dir/2`; never `__DIR__` (see Decision 9)

## 5. Conformance vectors and property tests

- [x] Generate the conformance vector file from the predicate specification — the fixture set IS
      the vector file; one artifact, so a rule cannot gain a fixture without gaining a vector
- [x] Include violation identity (code, field path) in every vector, not just accept/reject —
      compared as an ORDERED SEQUENCE of `(code, field_path)`, not as a set and not as
      accept/reject. Three implementations can reject the same input for three different reasons
      and a bare rejection assertion stays green
- [x] Include the negative fixtures from phase 3 as vectors — same artifact by construction
- [x] Implement the thin vector harness in **Rust** — `//config/validator:vector_test`. Until it
      existed the fixture file was inert data, and it found two real defects on its first run:
      every pre-existing fixture was stale against the `dgraph` schema addition, and 35 of 45
      rules had no fixture at all — the invariant the rule set file states in its own header and
      that nothing enforced.
      **Negative control verified on RBE:** silently widening `DATABASE_POOL_SIZE_RANGE` from
      `min: 1` to `min: 0` reds `database_pool_size_zero` with `expected [...] actual []`, which
      is the SEMANTICS.md section 8 property — weakening a rule makes its case pass, and the
      harness catches exactly that
- [x] Implement the thin vector harness in **Go** — `//config/go/validator`, engine plus
      harness. It reproduces all 47 fixtures as an ordered `(code, field_path)` sequence and
      revalidates all five committed instances.
      **Two negative controls verified on RBE.** Breaking `IntRange` to be exclusive at the upper
      bound was caught by the property test and shrank to `range [0,0] at 0` — the IDENTICAL
      minimal counterexample proptest produced in Rust. It did NOT red the vectors, because no
      committed fixture uses a max-boundary value; disabling `NonEmpty` instead failed 10 named
      fixture subtests. The two layers catch different things, which is why both exist
- [~] Vector harness in **Elixir** — engine and harness written and correct, but BLOCKED by a
      rules_elixir defect: `private/ex_unit_test.bzl:51` stages every test input with
      `src = s.path`, which for a GENERATED file is `bazel-out/<cfg>/bin/...` and does not resolve
      from the test's working directory. Source files work only because `path == short_path` for
      them. Fix is `src = s.short_path`; pinned commit 832a95b4. The vector test is excluded from
      the glob with that note rather than left red — see `config/elixir/BUILD.bazel`
- [x] Implement property-based tests per predicate law in **Rust** —
      `//config/validator:predicate_law_test`, 16 tests: eight proptest properties plus eight
      hand-written cases. Both layers are needed. The properties state each law as a universally
      quantified claim and SHRINK to a minimal counterexample on failure; the hand-written cases
      pin the specific points three implementations most easily diverge on.
      **A real defect in the first generator, found by running the control:** breaking the engine
      to make `IntRange` exclusive at the upper bound was caught by the hand-written edge case but
      NOT by `prop_int_range_is_inclusive_containment`, which drew `min`, `span` and `v`
      independently over 400k values and so reached `v == max` only by luck. The property was
      passing vacuously with respect to the boundary it claims to prove. Fixed by drawing the
      value RELATIVE to the bounds; the same control now fails and shrinks to
      `min = 0, span = 0, pick = 0` — the degenerate range `[0,0]` at its own edge.
      Sampling a boundary is not the same as testing it
- [x] Property tests in **Go and Elixir** — `pgregory.net/rapid` (7 properties) and StreamData
      (7 properties), mirroring the eight Rust ones. All three draw range values RELATIVE TO THE
      BOUNDS rather than independently, carrying forward the defect the Rust control exposed: an
      independent draw reaches `v == max` only by luck, so the property passes against an
      off-by-one engine. Sampling a boundary is not testing it.
      `rapid` was added to `go.mod` and registered by `bazel mod tidy` as `net_pgregory_rapid`;
      `stream_data` was already vendored
- [x] Confirm all suites are untagged and selected by `make test` — verified by
      `bazel query 'attr(tags, "manual|integration_test|acceptance_test", //config/...)'`: no test
      target under `//config/...` carries an excluding tag, so all 12 are selected by
      `--test_tag_filters=-integration_test,-acceptance_test`

## 6. Managers

- [ ] Implement `ConfigManager` natively in Rust, Go, and Elixir, keyed by `SERVICERADAR_ENV`
- [ ] **Validate at LOAD, in every implementation**, against the rule set shipped with the release
      — not only at build time. This is what lets an instance come from outside the repository
      without losing Decision 10's guarantee, and it is strictly stronger than today: a committed
      instance is currently validated at build and then trusted at load. See Decision 12
- [ ] Implement `SERVICERADAR_CONFIG_URI` with `file:` and `https:`; reject `http:`; fetch failure
      is fatal with NO cached fallback
- [ ] Hard-error when both `SERVICERADAR_ENV` and `SERVICERADAR_CONFIG_URI` are set, and when
      neither is. No precedence rule — precedence is where a stale selector becomes invisible
      rather than wrong
- **DEFERRED to the configuration-server specification:** artifact integrity over `https:`. The
      exposure is real — without verification against something the client knew beforehand,
      whoever controls the endpoint or its DNS controls the deployment's database host and TLS
      mode — but the mechanism depends on what serves the artifact (a digest pin cannot exist for
      anything rendered per client; a signature presumes a signing key the server design has not
      introduced). `file:` carries no such exposure and is the recommended source until then
- [ ] Shape the loader as a **resolver keyed by scheme**, returning the instance AND its
      provenance even when provenance is trivially "built-in: saas". An unknown scheme is a
      startup error listing the supported ones
- [ ] Enforce that reaching a config source needs **no ServiceRadar-managed secret** — platform
      workload identity only (K8s SA token, SPIFFE SVID, platform-mounted client cert). A
      component reading a config-source credential out of SecretManager is a bootstrap cycle:
      SecretManager needs configuration to know its provider
- [ ] Ship `serviceradar config compile <in.textproto> -o <out.binpb>` — Go, because only Go parses
      text format natively. Applies schema + rule set + credential-shape checks and refuses to emit
      an artifact that fails any of them, moving discovery from the customer's boot to their
      authoring
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
