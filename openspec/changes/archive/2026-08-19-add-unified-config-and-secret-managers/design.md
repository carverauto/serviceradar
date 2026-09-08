# Design — Unified Configuration and Secret Managers

## Context

`openspec/notes/env-var-inventory.md` records the measured starting state: 58 names read, 45
forwarded, 26 read-but-unforwarded, three naming schemes, fourteen alias pairs. This document
records the decisions that make the proposal implementable, including three places where the
obvious design is wrong.

---

## Decision 1 — Three buckets, not two: the role name is an identity

A PostgreSQL DSN embeds a password, so it cannot live in a checked-in file. But the *username* is
not a credential either — `srql_test` is a role name. It only looks secret because it shares the
DSN's userinfo with the password.

| Field | Bucket | Why |
|---|---|---|
| host, port, database, sslmode, TLS server name, pool size, search path | config | never secret |
| **connecting role, owning role** | **config** | identities, not credentials |
| password, client cert, client key, CA PEM | secret | credentials |
| the DSN | assembled at runtime | embeds a password |

Separating identity from credential deletes code rather than relocating it:

- `owner_from_url()` (`rust/integration-db/src/lib.rs:275`) exists **solely to parse a
  credential-bearing string to recover a role name** — the role that owns per-run test databases,
  consumed by `tests/provision_db_test.rs:84` and `src/bin/prepare_template.rs:43`. With the role as
  a config field, the function and its "must include a user" failure mode disappear.
- `SERVICERADAR_TEST_DATABASE_OWNER` exists to override that parse "for a fixture that deliberately
  separates the owning role from the connecting one". With two distinct fields, that is the ordinary
  case, not an override.
- `repoint_database()` (`lib.rs:218`) does string surgery to swap in the per-run database name.
  Under assembly the name is a computed field.
- `normalize_sslmode_for_tokio_postgres()` rewrites `verify-full` → `require` for the URL parser.
  Building driver config programmatically from a typed enum removes the parse, and the rewrite.

---

## Decision 2 — Protobuf schema, text-format instances, explicit presence

**Chosen:** schema in `config/proto/`, instances in `config/environments/*.textproto`.

All three languages already consume protobuf — prost in Rust, generated `*.pb.go`, and
`{:protobuf, "~> 0.16.0"}` in `serviceradar_core`, `datasvc` and `serviceradar_agent_gateway`. No
new dependency in any tree, and the schema *is* the cross-language contract.

**The proto3 trap, which would recreate the exact bug being eliminated.** All 13 existing protos are
`syntax = "proto3"` and none uses `optional`. Without explicit presence, a missing `port` decodes to
`0`, a missing string to `""`, and a missing enum to whatever is `= 0`. That is silent defaulting
relocated from `System.get_env(x) || default` into the decoder. Therefore:

- Every field that must be present is declared `optional` (proto3 explicit presence), and validation
  asserts **presence**, never merely decodability.
- Every enum reserves `0` as `*_UNSPECIFIED`, which validation rejects — so an unset TLS mode is an
  error, never accidentally the first real value.

### Authoring format vs loaded format — settled

**`.textproto` is committed and reviewed; `protoc` compiles it to binary at build time; every
manager loads the binary.** Two distinct artifacts with two distinct jobs:

| Artifact | Job | Where it lives |
|---|---|---|
| `config/environments/**.textproto` | authored, reviewed, diffed — the ground truth | git |
| compiled binary message | loaded at runtime by all three languages | Bazel action output, shipped in `priv/` for Elixir |

This is what makes the format choice work at all: **no language ever parses text format.** Only Go
reads textproto natively — `prost` does not, and Elixir's `:protobuf` has no parser at any version
(0.17.0's `Protobuf.Text` is encode-only). Moving the parse into a `protoc` build action removes the
requirement from all three implementations at once, and the action is declared, hermetic and cached
like any other.

A round-trip test asserts the generated binary matches its committed source, so the two cannot
drift.

**Rejected alternatives, and why:**

- **TOML/YAML + JSON Schema.** Friendlier to author, but yields untyped maps and needs a separate
  validator per language, so drift returns through the back door.
- **Declaring configuration programmatically in Rust**, emitting binary from a build target. It
  removes the parsing problem — but the parsing problem is already removed by the `protoc` step, so
  the trade buys nothing and costs three things: ground truth stops being reviewable data (a config
  change becomes a Rust code review); an ops or customer deployment engineer can no longer author an
  `onprem:<id>` instance, which Decision 10 explicitly places in this repo so they can; and code can
  read the environment (`std::env::var` in a builder), reintroducing the exact ambient-input disease
  this change exists to cure.
- **Starlark-generated instances.** A better version of the same idea — already the build language,
  a Bazel target by construction, and non-Turing-complete with no I/O, so it *cannot* read the
  environment. Held in reserve: if shared bases or per-customer overlays later justify computation,
  this is the escape hatch, emitting `.textproto` or binary. Not adopted now, because static data is
  the simpler thing and nothing yet needs computing.

---

## Decision 3 — Validation is a committed rule set over a closed predicate vocabulary

Validation logic is **data**, not code, so ground truth and drift protection are both git-tracked.

Rules are rows of `(field_path, predicate, params, phase, code)`. The predicate vocabulary is
**closed and small**:

```
required · non_empty · int_range · one_of · matches
required_if · forbidden_value · equal_across_envs
```

**Why a closed vocabulary rather than a general expression language.** protovalidate/CEL is the
obvious candidate and puts rules inside the `.proto`. Its viability turned on one fact — whether a
mature CEL implementation exists for Elixir — and that was checked (2026-08-17):

- **protovalidate has no Elixir implementation.** Official support is Go, JS/TS, Java, Python and
  C++ only.
- **The sole CEL implementation reachable from the BEAM is `cel` v0.3.1**, written in Gleam. Last
  release **2024-12-19** (~20 months stale), **532 downloads all time**, **0 in the last 7 days**,
  pre-1.0, single maintainer, with no stated CEL spec conformance.

That is disqualifying, and doubly so given the rule set is the security boundary of this design:
adopting CEL would put a stale, effectively unused pre-1.0 dependency on the critical path in one of
three languages, and leave that language's validation semantics defined by a library nobody
exercises. **The closed vocabulary stands.** It needs no third-party expression engine in any
language, so the Elixir question disappears entirely, and nine predicates are small enough to test
exhaustively. Adding a predicate later is a deliberate, reviewed act with its own conformance cases.

Revisit only if an Elixir-native protovalidate appears with real adoption; nothing else changes.

The bug-surface argument, quantified: hand-written checks scale as *fields × languages* (~58 × 3);
a rule set scales as *predicates × languages* (~8 × 3), with the rules themselves shared data.

**Rules carry a phase.** Some are checkable against the file alone (`every environment defines every
required field`); others only against config resolved together with secrets (`password is
non-empty` — the password is not in the file). Each rule is tagged `config`, `resolved`, or `both`.
Without this the build-time validator fails on rules it structurally cannot evaluate.

---

## Decision 4 — Formalize the engine, not the predicates

`non_empty` is trivial; three languages will agree on it by accident. Divergence lives in the
**composition semantics**, which are genuine specification questions with defensible answers either
way:

- A field is absent *and* carries `required` plus `int_range` — one violation or two? (Cascading.)
- Is evaluation short-circuit or exhaustive? This decides whether error output is **stable**, and
  unstable output makes cross-language vectors unusable.
- What is the ordering of reported violations? Must be deterministic or vectors cannot compare.
- A `resolved`-phase rule on a field absent at `config` phase — skipped, deferred, or an error?

These are the modelling target (TLA+/Alloy on traversal, phase handling, error aggregation and
ordering). Verified extraction to three languages is not realistic and is not attempted.

For the predicates the cheap, high-value property is **totality**: each is a pure total function
`(value, params) → Verdict` — no partiality, no panics, no ambient state. Most real divergence is
partiality (what does `int_range` do on a missing field, or a non-numeric string?). Totality forces
those answers into the spec once instead of into three implementations by accident.

---

## Decision 5 — Assurance ladder: properties, then vectors

Three layers, cheapest first. All are required; none subsumes another.

1. **Property-based tests per predicate**, over the algebraic laws — `one_of(v, S) ⟺ v ∈ S`,
   `int_range` monotone in its bounds, `required` the negation of absence. Available natively in all
   three trees (proptest, rapid/gopter, StreamData). These explore inputs no hand-written vector
   table will think of, and they are where predicate totality is actually exercised.
2. **A committed conformance vector file** — generated from the formal predicate spec, consumed by a
   thin (~50 line) harness per language. **Data, not generated code**: three generated test sources
   would be three more artifacts to keep in sync, recreating the problem. A single vector file is
   diffable, reviewable, and git-tracked.
3. **Violation identity in the vectors.** `{input, expected: REJECTED}` is too weak — three
   implementations can reject the same input for three different reasons and the suite stays green.
   Vectors carry `{input, expected_violations: [{code, field_path}]}`.

---

## Decision 6 — Least privilege: config by build graph, secrets by declaration

Configuration files are Bazel targets, so a target declares `data = ["//config:database_ci"]` and
**physically cannot see** NATS config — it is not in its runfiles. Enforced by the sandbox rather
than by discipline, and readable at the target definition instead of inferred from a global union.
This inverts today's model, where `database_env` forwards all 45 names to every database test action.

**The asymmetry:** a secret cannot be a build target, so the elegant `data` mechanism covers only
half the problem — and the half that carries credentials is the other one. The symmetric mechanism
is a per-component **declared secret manifest**: a component lists the logical secret names it may
request, and the provider refuses anything undeclared. Same "Go cannot see NATS secrets" property,
enforced at the provider.

**The sandbox property is strong in tests and weaker in deployment.** A release binary reads a
mounted file or Kubernetes secret, not runfiles, and `bazel run` targets inherit the ambient
environment — `prepare_template` already depends on this. Do not assume the build graph protects
production.

---

## Decision 7 — Environment identity is a pair `(kind, instance)`, not an enum

On-prem is multi-tenant by nature: a deployment at one customer and another elsewhere each need
their own configuration. So the selector is not a four-valued enum — it is a **kind plus an optional
instance**:

```
SERVICERADAR_ENV = <kind>[":" <instance>]

  localhost             ci                 saas
  onprem:acme         onprem:<customer>
```

Kept as **one variable** with a compound value rather than two variables, so the deployment boundary
stays a single knob. It parses into a typed `EnvironmentId { kind, instance }`; a missing instance
for `onprem` is an error, and an instance supplied for a single-instance kind is an error.

| Kind | Config source | Secret provider |
|---|---|---|
| `localhost` | `config/environments/localhost.textproto` | developer file under `~/.config/serviceradar/` |
| `ci` | `config/environments/ci.textproto` | BuildBuddy secret store (already populated) |
| `saas` | `config/environments/saas.textproto` | Kubernetes secret / OpenBao |
| `onprem:<id>` | `config/environments/onprem/<id>.textproto` | Kubernetes secret / operator-supplied file |

The provider owns the mapping from logical name (`database.password`) to whatever the platform calls
it. That is what retires the three-spellings problem: `NATS_CA_FILE` vs `NATS_CACERTFILE` vs
`NATS_TEST_CERT_DIR` becomes one logical name with per-provider bindings.

An unset or unrecognised `SERVICERADAR_ENV` is a hard error listing the valid kinds. Never a
fallback to `localhost`.

### Consequences of a variable instance set

- **Rules must be scoped.** `equal_across_envs` and any invariant such as "TLS is verified
  everywhere except `localhost`" must state whether they range over kinds, over every instance, or a
  named subset. A rule with no scope is ambiguous once instances multiply.
- **The completeness meta-rule iterates instances.** "Every environment defines every required
  field" must hold for each `onprem` instance, so a new customer file that omits a field fails the
  build — which is only possible if the build can see that file. See the open question below.
- **This is not multitenancy in the sense AGENTS.md forbids.** That rule bars per-customer routing
  and tenancy bypass *at runtime within one deployment*. Here each customer is a separate
  single-tenant deployment that selects one configuration at boot; nothing becomes tenant-aware.

### Where customer instance files live — settled by Decision 10

**In this repository, at `config/environments/onprem/<id>.textproto`**, alongside every other
instance. Decision 10 puts the whole configuration system in one tree; on-prem instances are not an
exception to it.

This deliberately takes the stronger of the two properties available:

- **The completeness meta-rule runs here.** Every on-prem instance is validated by the same
  build-time test as `ci` and `saas`, so a customer file that omits a required field, or sets a
  weaker TLS mode than the cross-environment invariant permits, fails **this** repository's build.
  Splitting instances into customer-scoped repositories would have moved that check into pipelines
  this repo does not control — which is how a validated system quietly becomes a partially validated
  one.
- **One diff shows a schema change and its effect on every deployment.** Adding a required field
  makes every instance that lacks it visibly red, including customers, in the same change.

The accepted cost is that customer topology — hostnames, endpoints, certificate subjects — lives in
this tree. Two things bound it, and both are already required by this design rather than added for
this decision: configuration files contain **no secrets** (enforced by the credential-shape check),
and everything customer-specific is *topology*, not credentials. If a particular customer's topology
is genuinely non-disclosable, that is an exception to negotiate for that customer, not a reason to
weaken validation for all of them.

---

## Decision 8 — Diagnostics are fail-closed, not better logs

The disease is silence, so the requirement is structural:

- **Resolve at startup, not at first use.** A component resolves everything it declared, up front. A
  missing value is an error naming the key, the environment, and the provider.
- **An `explain` target.** `bazel run //config:explain -- --env=ci --component=srql` prints every
  resolved value with **provenance** — which file or provider each came from — with secrets
  redacted. This is the single command that would have collapsed the investigation behind this
  change into one step.
- **Never log a resolved secret.** `redacted_database_url` already exists because someone hit this.

---

## Decision 9 — Elixir resolves everything before the application tree starts

**All** configuration values must be available before the Elixir application tree starts, which puts
the manager inside `config/runtime.exs` — evaluated at boot, before any application is started.
That constrains the Elixir implementation more tightly than the other two:

- **A plain module with pure functions.** No GenServer, no supervised process, no ETS owned by a
  supervisor, no `:persistent_term` populated at application start. Anything requiring a *started*
  application is unavailable at that point.
- **No NIF.** Already ruled out for other reasons, but this closes it independently: a Rustler NIF
  lives in an application that must be loaded, and its failure at boot would be unsupervised.
- **The instance file must ship inside the release** and be locatable at boot. A path that resolves
  in `mix test` but not in a release is the failure this would produce, so release packaging is a
  first-class task, not an afterthought.

### Verified against a real Mix release (2026-08-17)

**Calling code at boot works; starting applications does not.** A release was built and
`runtime.exs` instrumented. Started applications at that point are only `:kernel`, `:stdlib`,
`:elixir`, `:compiler` — but every application is *loaded* and every module is on the code path, so
any dependency or project module can be called. `GenServer.call` exits `:noproc`, a
supervisor-owned ETS table is `:undefined`, and `:persistent_term` written at app start is absent.
This repo already relies on the working half extensively — `Jason.decode!` and project modules are
called from `runtime.exs` in all four Elixir projects.

**`Application.ensure_all_started/1` is available and is a trap.** `Config.Provider` computes
configuration and then **restarts the VM** so applications boot with final config. Anything started
inside `runtime.exs` therefore runs twice, and the first run reads *pre-runtime* configuration. A
process-based ConfigManager would silently resolve against the wrong config on its first pass. The
manager must stay pure functions over loaded modules.

**File location: `Application.app_dir/2` works at boot** — it delegates to `:code.lib_dir/1`, which
consults only the code path, so it needs no started application. Ship the instance in an app's
`priv/`, which `mix release` copies to `<root>/lib/<app>-<vsn>/priv`; the repo already depends on
this for migrations. **Do not use `__DIR__`** — `runtime.exs` is copied to
`<RELEASE_ROOT>/releases/<vsn>/`, so `__DIR__` is the release version directory, not the source
tree.

### Resolved: Elixir cannot read text format, so the loaded artifact is generated

**`:protobuf` has no textproto decoder at any version.** The pinned 0.16.1 has no text-format module
at all (verified in the vendored source: `lib/` contains only binary and JSON). Version 0.17.0 added
`Protobuf.Text`, but it is **encode-only** — a single `encode/2`, no parser. Protox does not parse it
either. Rust's `prost` likewise has no text-format support; of the three, only Go reads textproto
natively.

Therefore the committed `.textproto` is the **authoring and review** format, not the loaded one:

> A Bazel action compiles each committed `.textproto` into a binary artifact (`protoc --encode`),
> and all three managers load the binary. A test asserts the generated artifact round-trips to its
> committed source, so the two cannot drift. The human-facing artifact stays reviewable in a diff;
> the machine-facing one stays loadable everywhere.

This is a strength rather than a concession: the conversion is a declared build action with inputs
and outputs, so it is cached, hermetic, and identical for all three languages — and the generated
binary is what ships in `priv/`, which is exactly what the boot-time constraint above requires.

---

## Decision 10 — Everything lives in one `config/` tree

**A deliberate exception to the repository's language-tree layout.** Normally protos live in
`proto/`, Rust crates in `rust/`, Go packages in `go/pkg/`, Elixir projects in `elixir/`. Here the
schema, the rule set, the negative fixtures, the conformance vectors, the formal model, and all
three implementations live together:

```
config/
  proto/          config.proto, rules.proto            schema + rule-set schema
  environments/   localhost|ci|saas.textproto,
                  onprem/<id>.textproto                the committed instances
  rules/          ruleset.textproto, fixtures/         rules + one violating fixture per rule
  vectors/        conformance.textproto                generated, committed
  model/          engine.tla                           formal engine semantics
  rust/           crate                                ConfigManager / SecretManager
  go/             package                                     "
  elixir/         mix project                                 "
  BUILD.bazel     + per-subdirectory BUILD files
```

**Why the exception is justified rather than merely convenient.** These artifacts are one thing that
must change together: adding a field touches the schema, the instances, the rule set, a negative
fixture, the vectors, and three readers. Splitting that across four trees is precisely the mechanism
that produced the current drift — the schema of record was `.bazelrc`, the readers were three trees
away, and nothing connected them. Co-location makes an incomplete change visible in one diff, and
makes the reviewer of a schema change the same person looking at its rules and its fixtures.

Record this in `AGENTS.md`, or a future cleanup will "fix" the layout and undo it.

**Verified layout constraints:**

- **Cargo:** already has workspace members outside `rust/` — `proto/dgraph`,
  `elixir/serviceradar_core/native/anomaly_disposition_nif` — so `config/rust` breaks no convention.
  Add it to `[workspace] members`.
- **Go:** the module root is `github.com/carverauto/serviceradar`, so `config/go/` is importable as
  `github.com/carverauto/serviceradar/config/go/...`. Consider naming the directory something other
  than `go` to avoid `config/go/go.go`-style paths.
- **Elixir:** a Mix project at `config/manager_validator/elixir/`, referenced by path from consuming `mix.exs` files.
  **Naming hazard:** every Mix project already has its own `config/` directory
  (`elixir/web-ng/config/runtime.exs` and three others). A repository-root `config/` is a different
  thing with the same name. Unambiguous in a full path, ambiguous in conversation — worth a
  different top-level name if that friction is judged too high.
- **Bazel:** one package tree with per-subdirectory BUILD files, exposing `//config:...` targets for
  the schema, each instance, the rule set, the vectors, and each implementation.

---

## Decision 11 — Scope boundary against the existing config machinery

The audit behind this change covered the **48 names in `database_env` / `nats_env`**. The repository
also contains a second, older configuration system that the audit did not measure:

- `go/pkg/config/` — `config.go`, `env_loader.go`, `file_loader.go`, `diff.go`, plus `kv/`,
  `kvgrpc/`, `kvnats/` and `bootstrap/`. It has its own environment variables — `CORE_SEC_MODE`,
  `CORE_CERT_FILE`, `CORE_KEY_FILE`, `CORE_CA_FILE` (`bootstrap/core_client.go`) — none of which
  appear in the inventory note.
- `rust/config-bootstrap` — whose own doc comment says it "mirrors the file-based portion of Go's
  `pkg/config/bootstrap`". Consumed by `rust/log-collector`, `rust/flow-collector`,
  `rust/rperf-client`; the Go side by `go/cmd/data-services`, `go/cmd/faker`.

So there is **already a second pair of parallel config loaders kept in sync by hand** — the same
failure shape this change exists to remove, one layer up.

**Resolved: the bootstrap layers are rebuilt on the managers.** They are not deleted and not left
alone — they become **consumers**. There are two layers and they compose:

| Layer | Owns | Implementation |
|---|---|---|
| Environment configuration | what differs between `localhost`, `ci`, `saas`, `onprem:<id>` — endpoints, TLS posture, roles, and the secrets bound to them | `config/` — `ConfigManager` / `SecretManager` |
| Service bootstrap | a single service's own instance config: file on disk, KV-delivered runtime config, overlay precedence | `rust/config-bootstrap`, `go/pkg/config/bootstrap`, and a new `elixir/config/bootstrap` |

Each bootstrap library keeps its job — loading and overlaying a service's own configuration — but
**stops reading the environment itself**. Every environment-dependent value it needs (core endpoint,
security mode, certificate material, database and NATS coordinates) comes from the ConfigManager for
the active `SERVICERADAR_ENV`. Elixir gains a symmetric `elixir/config/bootstrap` so all three trees
have the same two-layer shape instead of two trees having it and one improvising.

Consequences for scope:

- The `CORE_*` family (`CORE_SEC_MODE`, `CORE_CERT_FILE`, `CORE_KEY_FILE`, `CORE_CA_FILE` at
  `go/pkg/config/bootstrap/core_client.go`) is **in scope** and must be surveyed into the schema
  before phase 2, or the schema is designed against half the problem.
- The bootstrap libraries' existing consumers — `rust/log-collector`, `rust/flow-collector`,
  `rust/rperf-client`, `go/cmd/data-services`, `go/cmd/faker` — are unaffected at their own call
  sites; the change is beneath them.
- `rust/config-bootstrap` no longer needs to "mirror the file-based portion of Go's
  `pkg/config/bootstrap`" by hand. Both mirror the same schema, rule set and vectors, so the parity
  that is currently maintained by discipline becomes a tested property.

This turns the second parallel-implementation problem into an instance of the first, solved by the
same machinery, rather than a separate cleanup deferred indefinitely.

---

## The limit worth naming

A verified engine faithfully applies whatever rules it is given. It cannot detect that the rule set
**forgot** to require `sslmode`. That is spec completeness, not correctness, and no rigor on the
engine touches it — while a verified engine is a *stronger* green signal, so it carries more false
confidence if the rule set is thin. Given that this change exists because green signals asserted
nothing, that risk is taken seriously and mitigated mechanically, not by intent:

- **Meta-rule:** every schema field must carry at least one rule. A new field with no constraints
  fails the build.
- **Negative fixture per rule:** each rule has a committed config that violates it and must be
  rejected, so deleting or weakening a rule turns a test red.
- The rule set is CODEOWNERS-gated and small enough to read in one sitting.

### Failure map

| Failure | Caught by |
|---|---|
| Bad configuration authored | Build-time validator (Bazel test) |
| Engine implementation diverges | Conformance vectors with violation identity |
| Predicate partiality | Totality + property-based tests |
| Rule deleted or weakened | Negative fixtures |
| **Rule set incomplete** | **Nothing automatic — meta-rule plus review** |

Four of five move to design and build time. The fifth stays a human problem, and is stated here
rather than left implied.

## Open questions for review

1. ~~Is the environment set exactly `localhost`, `ci`, `saas`, `onprem`?~~ **Resolved 2026-08-17:** the
   kinds are those four, but on-prem is multi-instance, so identity is `(kind, instance)` — see
   Decision 7.
2. ~~Does a mature CEL implementation exist for Elixir?~~ **Resolved 2026-08-17: no.** protovalidate
   has no Elixir implementation; the only BEAM-reachable CEL is a stale pre-1.0 Gleam library. See
   Decision 3. The closed predicate vocabulary is adopted.
3. ~~Are `.textproto` instances committed or generated?~~ **Resolved 2026-08-17: committed, always
   in git.**
4. ~~Which values must exist before the Elixir application tree starts?~~ **Resolved 2026-08-17:
   all of them** — see Decision 9.

5. ~~Where do on-prem customer instance files live?~~ **Resolved 2026-08-17: in this repository**, at
   `config/environments/onprem/<id>.textproto`, per Decision 10 — everything in one `config/` tree.

**Nothing is blocking phase 2.** One technical question remains inside Decision 9 — whether Elixir's
`:protobuf` decodes text format — but it has a sound fallback (committed textproto as ground truth
plus a build-generated binary companion, with a drift check between them), so it constrains release
packaging rather than the design.

---

## Decision 12 — One variable, and the environment decides everything else

`SERVICERADAR_ENV` is the **only** input a component reads. It is required, has no default, and
from the identity it names both managers derive everything: which instance to load, where that
instance comes from, and which provider resolves secrets. A component never learns a second
variable name.

**No default, deliberately.** A guessed environment is a guessed database, and guessing wrong is
silent -- the process starts and connects somewhere nobody chose. The failure message is treated
as part of the interface and asserted by a test, because the one thing worse than this error is
this error explained badly to someone in a crash loop at 3am.

### REVISED: validation stays, the rule set stops being a parameter

Loading still validates -- there is no entry point that returns an unvalidated value, and that
invariant is unchanged. What changed is who supplies the rules.

`load` originally took `&RuleSet`, which made the rule set part of every caller's dependency
graph. That was the wrong shape twice over. It claimed the rules vary, when they vary by nothing:
not by environment, not by component, not by deployment. And it leaked an implementation concern
of the config layer into the API of every consumer -- a service had to obtain the rules before it
could obtain its configuration, and the only mechanism available was runfiles, which a container
does not have. That is what blocked `rust/srql` from using ConfigManager at all.

The rules are now an internal dependency of the config layer, embedded at build time. All three
implementations do the same thing: Rust `include_bytes!`, Go `go:embed`, Elixir a compile-time
module attribute with `@external_resource`.

**Embedded, not mounted beside the instance.** The instance is read from a mount at runtime --
untrusted, and the thing being verified. Reading the rules from that same mount would let
whatever supplied a bad instance supply the rules that bless it, which proves nothing. The
asymmetry is the point: trusted rules, untrusted instance.

**Committed, with a drift guard.** `include_bytes!` and `go:embed` need a real file that `cargo`
and `go test` can reach, and `go:embed` cannot reach outside its own package -- so there is one
copy per language, exactly like the generated protobuf bindings, and guarded the same way. Three
`diff_test`s compare each copy against protoc's output for `config/rules/ruleset.textproto`, so
the copies cannot disagree with the source or each other.

**No test may inject a rule set.** A manager test that validates against invented rules is not
testing the system: it tests the manager against rules no deployment has, and it lets the valid
fixture drift from what the committed rules actually require. The synthetic rule sets in all
three languages were deleted, and the fixtures now satisfy the real 45 committed rules.

### The source follows from the kind

| Kind | Instance comes from |
|---|---|
| `localhost`, `ci` | carried in the artifact |
| `saas`, `demo`, `onprem:<id>` | mounted at `/etc/serviceradar/environment.binpb` |

`localhost` and `ci` carry theirs because neither has a platform to mount anything: a developer
running `cargo run` and a Bazel test action both have a filesystem nobody provisioned. Every
deployed kind reads the mount, and the mount path is a **constant, not a variable** -- a settable
path would be a second thing that can disagree with the first.

This is also what solves the enterprise case that motivated this decision. **This repository is
public**, and an on-prem customer will not publish their database hosts and certificate subjects
to it. They mount their own compiled instance at that path and set
`SERVICERADAR_ENV=onprem:<their-id>`. Their topology never enters this tree, and they learn no
mechanism beyond the one variable every deployment already sets.

*Rejected: a second variable naming the source.* An earlier draft of this decision added
`SERVICERADAR_CONFIG_URI` beside `SERVICERADAR_ENV`, with both-set as an error. It made two
things able to name the configuration and put a path where the design wants a kind, and it
forfeited the identity check below. One variable plus a mount convention does the same job with
less surface.

### The artifact must describe the environment that was selected

The instance is self-describing -- `kind` and `instance` are fields in the message -- and the
selector is declared, so the two are compared at load:

> `SERVICERADAR_ENV=onprem:untd` must load an instance whose `kind` is ONPREM and whose
> `instance` is `untd`. A mismatch is a startup error naming both.

This catches **the wrong artifact being mounted**: the saas ConfigMap in the demo cluster, or one
customer's instance in another's deployment. That mistake is otherwise completely silent, and its
blast radius is the database a component connects to and the name it verifies TLS against. It
costs two comparisons because both halves already existed.

### Validation moves to load time

Decision 10's real content is not *config lives in git*. It is:

> no instance is ever loaded that has not been validated against the committed rule set.

Committing instances is one way to obtain that and not the strongest -- a committed instance is
checked at BUILD time and then trusted. So the guarantee moves: **ConfigManager validates whatever
it loads, before returning a single value**, against a rule set shipped with the release.
Build-time validation stays, demoted from *the* check to an *early* one that fails in CI rather
than at a customer's deploy. A mounted instance the build never saw is held to the same rules.

### Non-goal: the configuration server

A dedicated configuration server -- serving instances over an authenticated channel, rendered per
deployment -- is **out of scope** and a follow-up specification. What is in scope is that nothing
here stands in its way:

**1. Loading returns the instance AND its source**, from the first version, even when the source
is trivially a built-in name. `explain` has to report where a value came from; a server adds
endpoint, fetch time and verified identity, and there is nowhere to put them if loading returns a
bare `EnvironmentConfig`.

**2. Reaching the source SHALL NOT require a ServiceRadar-managed secret.** This is the one that
would actually block a server, and it is a **bootstrap cycle**: a server authenticates its
clients, authenticating needs a credential, credentials come from SecretManager, and SecretManager
needs configuration to know its provider. Broken by requiring the source to be reachable with
**platform-provided workload identity alone** -- a Kubernetes service account token, a SPIFFE SVID,
or a platform-mounted client certificate. ServiceRadar already deploys with SPIFFE and mTLS, so
that identity exists before any ServiceRadar configuration is read. Reading bytes is behind a
narrow interface for exactly this reason: the manager never decides how a deployment reaches its
own configuration.

**3. Validation stays on the client.** A server is not trusted to have validated what it serves.
This is what makes one *safe to plug in* rather than a new thing to trust, and it falls out of the
decision above rather than needing anything extra.

**4. Artifact integrity over a network is deferred** to that specification. The exposure is real
and recorded so it is not lost -- without verifying a fetched artifact against something the
client knew beforehand, whoever controls the endpoint or its DNS controls where a deployment
connects. It cannot be settled here because the mechanism depends on what serves the artifact: a
digest pin cannot exist for anything rendered per client, and a signature presumes a signing key
the server design has not introduced. A mounted file carries no such exposure; it arrives over the
same trust path as the container image.

**Explicitly not promised: hot reload.** Decision 9 requires the first resolution to be
synchronous and complete before the application tree starts, so any server must support a fetch at
boot. Push or lease can layer on later as an addition to that, never a replacement -- and the
resolved configuration stays immutable behind one accessor, so a future refresh replaces a value
rather than reworking every call site.
