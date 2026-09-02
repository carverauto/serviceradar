# Tasks

Ordered by blast radius, smallest first. **Do not collapse phases.** The inventory note documents
three cases where a static read-scan missed a live consumer — a `bazel run` target inheriting the
ambient environment, a test asserting on `.bazelrc`, and a value read under a different spelling.

## 1. Settle the open decisions

- [x] Confirm the environment set — **kinds are `localhost`, `ci`, `saas`, `onprem`, but on-prem is
      multi-instance**, so identity is `(kind, instance)` encoded as `<kind>[:<instance>]`
      (e.g. `onprem:acme`). See design.md Decision 7
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
- [x] Wire Rust codegen (prost) — `//config/proto_bindings/rust:config_schema`, crate
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
- [~] Model the engine (TLA+/Alloy) against those semantics — DESCOPED to
      `complete-config-manager-adoption`. `config/SEMANTICS.md` specifies the engine and the three
      implementations are pinned to it by shared vectors and property tests; a machine-checked
      model is additive assurance, not a blocker for the capability.
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
      `//config/manager_validator/rust:meta_rule_test`, over `//config/proto:config_descriptor_set`. The field
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
      cut by `//config/tools/rust:extract_section`. This is Decision 6 (least privilege), not caching:
      a target that declares one section PHYSICALLY CANNOT SEE the others, because they are not in
      its runfiles — absolute under remote execution, where only declared inputs reach the executor.
      `//config/manager_validator/rust:section_privilege_test` declares exactly one section and asserts both
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
      `//config/manager_validator/rust:credential_shape_test`. Four shapes (URL userinfo, `password=`-style
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
      — `//config/manager_validator/rust:round_trip_test`. Both sides are flattened to `path=value` pairs and
      compared structurally, because the committed file carries comments and blank lines no
      encoder emits, and neither prost nor Elixir's `:protobuf` can parse text format.
      Its weight comes from the two sides being READ FROM DIFFERENT PLACES — source tree vs.
      decoded artifact — so it becomes load-bearing when the binary is copied into a release
      artifact's `priv/` rather than read out of bazel-bin. Within one build the two cannot
      diverge, so the in-test negative control (corrupt one side, confirm the comparison
      notices) is what proves the comparison works
- [~] Ship the compiled binary inside release artifacts — for Elixir, into an app's `priv/`, read at
      boot with `Application.app_dir/2`; never `__DIR__` (see Decision 9) — DESCOPED to
      `complete-config-manager-adoption`. Test actions take the instance as a declared Bazel input
      (`//config/environments:<kind>_binpb` in `data`), which is what the migrated call sites use;
      packaging it into a release matters only once a deployed service loads through the manager,
      which is that change's phase.

## 5. Conformance vectors and property tests

- [x] Generate the conformance vector file from the predicate specification — the fixture set IS
      the vector file; one artifact, so a rule cannot gain a fixture without gaining a vector
- [x] Include violation identity (code, field path) in every vector, not just accept/reject —
      compared as an ORDERED SEQUENCE of `(code, field_path)`, not as a set and not as
      accept/reject. Three implementations can reject the same input for three different reasons
      and a bare rejection assertion stays green
- [x] Include the negative fixtures from phase 3 as vectors — same artifact by construction
- [x] Implement the thin vector harness in **Rust** — `//config/manager_validator/rust:vector_test`. Until it
      existed the fixture file was inert data, and it found two real defects on its first run:
      every pre-existing fixture was stale against the `dgraph` schema addition, and 35 of 45
      rules had no fixture at all — the invariant the rule set file states in its own header and
      that nothing enforced.
      **Negative control verified on RBE:** silently widening `DATABASE_POOL_SIZE_RANGE` from
      `min: 1` to `min: 0` reds `database_pool_size_zero` with `expected [...] actual []`, which
      is the SEMANTICS.md section 8 property — weakening a rule makes its case pass, and the
      harness catches exactly that
- [x] Implement the thin vector harness in **Go** — `//config/manager_validator/go`, engine plus
      harness. It reproduces all 47 fixtures as an ordered `(code, field_path)` sequence and
      revalidates all five committed instances.
      **Two negative controls verified on RBE.** Breaking `IntRange` to be exclusive at the upper
      bound was caught by the property test and shrank to `range [0,0] at 0` — the IDENTICAL
      minimal counterexample proptest produced in Rust. It did NOT red the vectors, because no
      committed fixture uses a max-boundary value; disabling `NonEmpty` instead failed 10 named
      fixture subtests. The two layers catch different things, which is why both exist
- [x] Vector harness in **Elixir** — `//config/manager_validator/elixir:unit_tests_validator_vector_test`. It
      required fixing rules_elixir: `ex_unit_test` staged every test input by `File.path`, so a
      GENERATED `srcs` or `data` entry resolved to `bazel-out/<cfg>/bin/...` and existed nowhere
      at test time. Source inputs hid it because their `path` and `short_path` are equal. Staging
      now uses short_path, with external inputs placed under `external/` so they cannot escape
      TEST_TMPDIR; `srcs_args` had the same latent bug and is fixed with it.
      **Verified on RBE:** disabling Elixir's `NonEmpty` reds the harness naming
      `database_name_empty` and `core_address_empty`, and all 25 pre-existing Elixir test targets
      pass with `--nocache_test_results` against the patched rule — the cached run reported
      "Executed 0 out of 25" and proved nothing
- [x] Implement property-based tests per predicate law in **Rust** —
      `//config/manager_validator/rust:predicate_law_test`, 16 tests: eight proptest properties plus eight
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

- [x] Implement `ConfigManager` natively in **Rust, Go and Elixir**, keyed by `SERVICERADAR_ENV` —
      `//config/manager_config/{rust,go,elixir}`. All three share the shape: one variable, source
      derived from the kind, identity cross-check, and loading that validates.
      The set of instances compiled INTO the release is passed in as `BuiltIns` rather than
      embedded, because embedding is the same problem as shipping the binary in a release
      artifact; solving it twice, differently, is how the two drift
- [x] **Validate at LOAD, in every implementation** — `load` resolves, decodes, checks identity
      AND validates as one operation. There is deliberately no entry point that returns a value
      having skipped any of the four
- [x] **Reject the wrong artifact**: the loaded instance's `kind`/`instance` must match what
      `SERVICERADAR_ENV` named. Catches the saas ConfigMap mounted into demo, and one on-prem
      customer's instance in another's deployment
- [x] Implement `SecretManager` — `//config/manager_secret/rust`. Two properties are enforced by
      TYPES rather than by discipline. A `Secret` cannot be printed: `Debug` and `Display` are
      hand-written to redact, the value is reachable only through `expose()`, and a test proves
      redaction survives nesting in `Option`, `Vec`, tuples and `Result` — because `{:?}` reaches
      secrets through tracing spans, `unwrap` panics and error chains, none of which look like
      printing a password at the call site. And empty is NOT a secret: a provider returning an
      empty string has failed, and treating it as a value is how a component connects with a blank
      password
- [x] Implement per-component declared secret manifests; provider refuses undeclared names —
      configuration gets least privilege from the build graph, but a secret cannot be a build
      target, so the symmetric mechanism is the manifest. **Refusal precedes resolution**: an
      undeclared name is refused identically whether or not the store holds it, because answering
      it even to say "not found" reveals whether a secret the component may not have exists
- [x] Hard-error on unresolvable secret, naming logical key and provider — with no default and no
      empty fallback, and the message states the consequence ("would authenticate with a blank
      credential") rather than only the fact
- [x] Implement startup resolution of everything a component declares — `resolve_all`. A component
      resolving lazily discovers a missing secret when it first needs it, under load and far from
      the deploy that caused it
- [x] Implement DSN assembly from typed fields plus resolved secrets — and **the DSN is itself a
      redacting type**. The DSN is not a schema field precisely because it embeds a password; that
      reasoning does not stop at the schema, so returning a bare `String` would undo the redaction
      SecretManager provides. `sslmode` comes from the typed TLS mode, and userinfo is
      percent-encoded: a password containing `@` or `:` would otherwise truncate the host or the
      role, producing a DSN that parses into something else rather than failing
- [x] Implement `SecretManager` in **Go and Elixir**, mirroring the Rust shape.
      **Elixir needed a different mechanism, and a test found out why.** A custom `Inspect` impl is
      not enough on the BEAM: a struct IS a map, so `inspect(term, structs: false)` renders it as
      one and prints every field, bypassing the protocol -- as does anything that walks the term,
      including a crash report. The value is therefore held in a CLOSURE, not a field; a closure's
      environment is not rendered. Verified against `structs: false`, `Map.from_struct/1` and
      `term_to_binary/1`. Go needed `GoString` as well as `String`, since `%#v` prints the struct
      literal
- [x] Implement the `explain` command with provenance and redaction — every reported value
      carries its origin, including one compiled into the release, because "it was built in" is an
      answer and omitting it leaves open the question this system exists to close. Enums are
      reported by NAME, not by number.
      Secrets are **absent, not redacted**: `Explanation` has no way to reach a secret value at
      all, which is stronger than remembering to mask one, and a masked value beside a name is one
      formatting change away from an unmasked one

**Empirical verification.** Every safety property in this phase is verified by MUTATION, not
asserted. Removing the identity cross-check, skipping validation, accepting an instance on a
single-instance kind, defaulting an unset variable, printing a `Secret` from `Debug` or `Display`,
accepting an empty secret, removing the manifest check, printing a `Dsn`, dropping `sslmode`, and
skipping percent-encoding each fail exactly the tests that name them, with no mutation uncaught.

## 7. Refactor every known call site onto the managers

Every direct environment read below is replaced by a `ConfigManager` / `SecretManager` call in that
file's own language. The list is the complete set of readers measured in
`openspec/notes/env-var-inventory.md` §6; a file is done when it contains no `env::var`,
`System.get_env`, or `os.Getenv` for a schema-covered name.

**Exit criterion for the whole phase:** an automated check fails the build if any of these
retrieval calls reappears for a schema-covered variable.

**Measured scope, Elixir (`elixir-inventory.md`).** That exit criterion covers 58 of the 676
distinct environment names Elixir reads, across 127 of 1173 read sites. The remaining 545 names
have no schema field yet, 91 read sites compute the variable name at runtime and are invisible to
any grep-based gate, and 301 names are supplied by Helm -- so 7b/7c as written
below are a real but partial step, and "zero environment reads" needs the plan in
`elixir-inventory.md` section 7 on top of them. Read that document before starting 7b: it also
lists 63 usage-proven alias pairs to collapse first (which is a pure Elixir edit), and the
partitioning the config managers need so one config change does not invalidate every target.
Section 3.1 is the argument for the whole change: 350 names are set by nothing in this
repository, and when absent, six raise while 340 silently change behaviour.

### 7a. Rust — fixture lifecycle first (smallest blast radius)

- [x] `rust/integration-db/src/lib.rs` — 9 reads: `SRQL_TEST_DATABASE_URL`, `SRQL_TEST_ADMIN_URL`,
      `SERVICERADAR_TEST_ADMIN_URL`, `SERVICERADAR_TEST_DATABASE_OWNER`,
      `SRQL_TEST_DATABASE_CA_CERT`, `PGSSLROOTCERT`, `PGSSLSERVERNAME`, `GITHUB_RUN_ID`,
      `GITHUB_RUN_ATTEMPT`
- [x] Delete `owner_from_url`, `repoint_database`, `normalize_sslmode_for_tokio_postgres`
- [x] Delete `require_verified_tls` once TLS mode is typed end to end
  - `GITHUB_RUN_ID` / `GITHUB_RUN_ATTEMPT` did NOT move to `ConfigManager`. They are a run
    correlation id, which varies per RUN, not per environment, so a committed instance cannot
    hold one. They became the Bazel flag `--//build:run_id`, materialised by `//build:run_id_file`
    and read from runfiles by both Rust and Elixir -- one producer of the format instead of two
    hand-synced implementations, and no constant fallback for two runs to collide on.
- [x] `rust/integration-db/tests/provision_db_test.rs` — `SERVICERADAR_TEST_DB_SHARDS` needs NO
      change: it is set by the target's own `env` in BUILD.bazel from
      `//build:integration_shards.bzl`, so it is a declared build input, not ambient state. It is
      env rather than `args` because libtest reads a bare argv entry as a test-name FILTER, which
      once made the target pass having provisioned nothing.
- [x] `rust/integration-db/src/bin/prepare_template.rs` — now zero ambient reads. `$GITHUB_OUTPUT`
      is gone: it was a GitHub Actions concept BuildBuddy does not set, faked in the workflow with
      a temp file that was then grepped back. The caller branches on the line the binary prints,
      which preserves the skip that saves 28.8-45.6s of BEAM startup.
- [x] `integration_tests/srql/tests/support/harness.rs` — 1117 -> 691 lines, zero schema-covered
      env reads (only `CARGO_MANIFEST_DIR`, the cargo fixture-path fallback). The DSNs are
      assembled from typed fields instead of mined for the owner and database name, which
      retired `parse_fixture_pg_config`, `normalize_sslmode_for_tokio_postgres`,
      `normalize_fixture_pg_connection_string`, `normalize_postgres_url`, `parse_host_port`,
      `quote_pg_keyword_value`, `percent_decode`, `decode_hex_digit`, `read_env_value`,
      `FixtureRootCert` and `TemporaryCaCert`. TLS resolves through srql's own
      `DatabaseTls::resolve`, so the harness verifies the fixture by the code path the service
      uses rather than a second implementation.
- [x] `rust/srql/src/config.rs` — all five `PGSSL*` reads gone. `DatabaseTls::resolve` takes the
      posture and verification name from the committed instance and the three PEMs from
      SecretManager, so no combination of variables can describe a server the process is not
      talking to. `AppConfig` now carries PEM CONTENT, not paths.

### 7b. Elixir — test configuration

**Prerequisite added by the CI fix: `EnvProvider` exists only in Rust.**
`config/manager_secret/rust` now has `EnvProvider` (logical name -> `SERVICERADAR_SECRET_*`) and
`EnvironmentProvider::for_kind`, which selects env for every kind except `localhost`. That
selection is what the platform actually does -- `//helm/serviceradar` supplies all 38 of its
credentials through `valueFrom.secretKeyRef`, and NOTHING anywhere mounts
`/etc/serviceradar/secrets`, so the `FileProvider` all three languages shipped with matches no
deployment that exists. Go and Elixir still have only `FileProvider`, so before either can
resolve a secret in CI or in the cluster:

- [x] Port `EnvProvider` + `EnvironmentProvider` to `config/manager_secret/elixir`, with the same
      name transform and the same "empty variable is absent, not an empty credential" rule.
      `FileProvider.for_kind/1` came with it, so `localhost` selects the file store in Elixir the
      way it does in Rust. `ServiceradarSecret.Names` mirrors Rust's `secrets.rs`, because the
      logical name is what the variable is computed from.
- [x] Cover it with the same tests the Rust side has (`tests/traits/`), including the mapping
      case -- the transform is the contract every `--test_env` list is derived from.
      `unit_tests_env_provider_test` and `unit_tests_environment_provider_test` mirror
      `env_provider_tests.rs` and `environment_provider_tests.rs` case for case.
- [~] The same port for `config/manager_secret/go` — DESCOPED to
      `complete-config-manager-adoption`. Go still ships `FileProvider` only, so no Go service can
      resolve a secret from the environment yet; nothing in 7d ships without it.

Two schema fields were added at the same time and are inert outside Rust: `database.admin_role`
(the role that may CREATE/DROP, because `connecting_role` deliberately lacks CREATEDB) and
`database.ca_bundle_url` (the CA is fetched from the published bundle, so no PEM is stored or
forwarded anywhere). Both carry validator entries and rules in all three languages already.

- [x] `elixir/serviceradar_core/test/db/template_env.exs` — resolves through
      `ServiceradarConfig.Manager` + `ServiceradarSecret`, so `//elixir/serviceradar_core:migrate_template`
      needs `SERVICERADAR_ENV` and one secret instead of a `SRQL_TEST_DATABASE_URL` whose host
      lived in a CI secret. The resolution moved into `test/db/fixture_config.exs` rather than the
      env script, because `test/db/integration_env.exs` needs the same thing and a second copy of
      "how to reach the fixture" is how the two drift. The compiled instance is a declared input
      (`//config/environments:{ci,localhost}_binpb` in `data`). Verified against the live fixture
      with a deliberately wrong password: everything up to authentication succeeded.

## Descoped to `complete-config-manager-adoption`

The capability is delivered and verified; what remains is ADOPTION -- migrating the rest of the
call sites, rebuilding the bootstrap layers, retiring the old machinery, and the deployment work.
That is a different kind of change with a different blast radius, and it was split out
deliberately rather than left as a long tail on this one.

Moved verbatim into that change:

- 7b (remainder) -- `config/test.exs`, `integration_env.exs`,
  `database_bootstrap_integration_test.exs`, the two `test_helper.exs`, `build/elixir_tests.bzl`
- 7c -- Elixir application configuration
- 7d -- Go, including the `EnvProvider` port it depends on, deleting `EnvConfigLoader`, and the
  `NATS_CREDSFILE` rename
- 7e -- the bootstrap layers
- 7f -- build-graph declarations and the end-to-end BuildBuddy verification
- 8 -- retiring `buildbuddy_setup_fixture_env.sh`, `scripts/ci/configure-srql-fixture.sh` and the
  `.bazelrc` profiles
- 9 -- `SERVICERADAR_ENV` in Compose/Helm/Kubernetes, CODEOWNERS, demo boot, developer docs

Two items from earlier phases moved with them and are marked `[~]` where they stand: the
machine-checked model of the engine (section 3) and shipping the compiled instance inside release
artifacts (section 4).
