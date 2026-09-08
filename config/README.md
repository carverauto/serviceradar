# ServiceRadar Configuration

One environment variable, `SERVICERADAR_ENV`, and everything else follows from the identity it
names: host, port, roles, TLS posture, endpoints -- and which store the passwords come from.

A component does not read a variable per setting. It does not name a provider. It does not parse
a DSN. It states which environment it is, and asks.

```
SERVICERADAR_ENV=ci
      |
      v
  Identity ---> ConfigManager ---> typed fields (host, port, roles, tls_mode, ...)
      |
      +--------> SecretManager  ---> the passwords and certificates those fields refer to
```

Everything under `config/` exists to make that one line true, and to make it impossible for two
implementations of it to disagree.

See `SEMANTICS.md` in this directory for the validation engine's formal semantics -- the verdict
type, predicate definitions, cascading, ordering and conformance obligations. This file covers
the system around it: what is here, how it is built and checked, and how to use it.

---

## 1. The contract

| | |
|---|---|
| Selector | `SERVICERADAR_ENV`, required, no default |
| Kinds | `localhost`, `ci`, `saas`, `demo`, `onprem:<instance>` |
| Instance source, `localhost` and `ci` | compiled into the artifact (a declared build input) |
| Instance source, deployed kinds | `/etc/serviceradar/environment.binpb` |
| Secret variable prefix | `SERVICERADAR_SECRET_` |
| Secret file store | `/etc/serviceradar/secrets`, or `$HOME/.serviceradar/secrets` on localhost |

`SERVICERADAR_ENV` is required and has no default, deliberately. A component that guessed an
environment would guess a database, and the wrong guess is silent. Empty counts as unset, because
this repository's build tooling pins several variables to `""`.

`onprem` is the one kind that carries an instance name (`onprem:untd`), because there is more
than one of them. The other four are single-instance and naming one is an error.

---

## 2. Layout

Schema, instances, rules, fixtures, formal model and all three implementations live in this one
tree. That is a deliberate exception to the repository's language-tree layout, because these
artifacts change together and splitting them across four trees is the mechanism that produced the
drift this replaces (design.md, Decision 10).

```
config/
  proto/            the schema                          config.proto, rules.proto
  environments/     the committed instances             ci, localhost, saas, demo, onprem/untd
  rules/            the rule set and its fixtures       ruleset.textproto, fixtures/
  SEMANTICS.md      the validation engine, formally

  proto_bindings/{rust,go,elixir}    generated schema bindings, committed
  manager_validator/{rust,go,elixir} the rule engine
  manager_config/{rust,go,elixir}    ConfigManager
  manager_secret/{rust,go,elixir}    SecretManager
  tools/rust                         build tooling for this tree
```

Component first, language second. The three implementations of ONE component must agree -- a
shape change lands in all three or the shared conformance vectors go red -- while two different
components in the same language need not. Grouping by language would put the things that must
agree in three different places.

---

## 3. The data

### Schema -- `proto/config.proto`

`EnvironmentConfig` is the root: a `kind`, an optional `instance`, and four sections.

| Section | Carries |
|---|---|
| `database` | host, port, database, `connecting_role`, `owning_role`, `admin_role`, `tls_mode`, `tls_server_name`, `ca_bundle_url`, pool sizing |
| `nats` | url, server name |
| `core` | address, api url, security mode, server name |
| `dgraph` | host, port, tls mode |

Every field is `optional`, for explicit presence: proto3 cannot otherwise tell "not set" from
"set to the zero value", and for a port those are very different statements.

**The schema carries no credentials.** It carries the TLS *mode* and the *server name*, but no
`*_cert_file` and no password -- a path to a credential is still a credential's location. Anything
a password or key could be recovered from belongs to SecretManager. A build-time check enforces
this; see section 6.

`ca_bundle_url` is the deliberate edge case: a CA bundle is what a client needs *before* it can
authenticate the custom CA's subjects, so it cannot itself be a SecretManager credential. It is
still configuration, and it is `https://` only: the hop that fetches it is terminated by a
publicly trusted cert, not by the custom CA being fetched.

### Instances -- `environments/*.textproto`

Ground truth, authored and reviewed as text. Nothing reads the text at runtime: a build action
compiles each to a binary message that every implementation loads.

Do not edit the generated `.binpb`.

### Rule set -- `rules/ruleset.textproto`

The semantic constraints, as data rather than code: `required`, `non_empty`, `int_range`,
`one_of`, `matches`, `required_if`, `forbidden_value`, `forbidden_if`, `equal_across_envs`, each
scoped to environments and to a phase (`config`, `resolved`, or both).

Rules are data so that three implementations enforce the same constraints by construction rather
than by three people reading the same paragraph.

### Fixtures -- `rules/fixtures/fixtures.textproto`

Conformance vectors: configurations paired with the violations they must produce. Every
implementation runs them. They are also what makes rule deletion detectable -- see section 6.

---

## 4. From textproto to a loaded value

`//config:defs.bzl` provides `environment_config`, `rule_set` and `fixture_set`. For each
instance, `environment_config` produces:

```
ci.textproto
   |  protoc --encode                       (unknown field or type mismatch fails the BUILD)
   v
ci.binpb                                    //config/environments:ci_binpb
   |
   +-- protoc --decode -> ci.canonical.textproto     round-trip check reads this
   |
   +-- extract_section  -> ci.database.binpb         //config/environments:ci_database
                           ci.nats.binpb             //config/environments:ci_nats
                           ci.core.binpb             //config/environments:ci_core
                           ci.dgraph.binpb           //config/environments:ci_dgraph
```

At load time, `ConfigManager::load` does four things and there is deliberately no entry point
that skips any of them:

1. **Read** the bytes -- from the built-ins the artifact carries, or from the mount.
2. **Decode** them against the schema.
3. **Confirm the artifact describes the identity that was asked for.** An instance for another
   environment is rejected rather than used.
4. **Validate against the rule set.** Loading validates, always; there is no unvalidated value.

---

## 5. Using it

### Rust

```rust
use serviceradar_config_manager::{ConfigManager, Filesystem, Identity};

let identity = Identity::from_env()?;
let built_ins: &[(&str, &[u8])] = &[("ci", ci_bytes)];
let manager = ConfigManager::load(&identity, built_ins, &Filesystem)?;

let db = manager.database().expect("validated at load");
let dsn = manager.database_url(&password);   // assembled, not parsed
```

### Elixir

```elixir
alias ServiceradarConfig.Manager
alias ServiceradarConfig.Manager.Identity

{:ok, identity} = Identity.from_env()
{:ok, manager} = Manager.load(identity, %{"ci" => bytes}, read_mounted_fun)

Manager.database(manager)
Manager.database_url_named(manager, "sr_core_template", password)
```

### Go

```go
id, err := manager.IdentityFromEnv()
loaded, err := manager.Load(id, builtIns, reader)
```

`read_mounted` / `reader` is a function rather than a hardcoded file read, so the manager never
decides how a deployment reaches its own configuration. That is what keeps the bootstrap acyclic:
reaching the configuration store must not itself require ServiceRadar-managed configuration.

### The DSN

`database_url` / `database_url_named` / `database_url_as` assemble a connection string from typed
fields. They return a `Dsn`, which **cannot be printed** -- it holds its value behind an `expose()`
call, and its `Debug`/`Inspect` render `[REDACTED DSN]`. An assembled DSN is as sensitive as the
password inside it.

The TLS server name is deliberately NOT in the DSN. It is a typed field handed to the TLS
connector, which is the only component that can act on it.

---

## 6. Least privilege, enforced by the sandbox

A target that declares `//config/environments:ci_database` **physically cannot see** the NATS
configuration -- it is not in that target's runfiles.

```python
rust_test(
    name = "my_db_test",
    data = ["//config/environments:ci_database"],   # database only
)
```

This is least privilege enforced by the build sandbox rather than by discipline, and it is
readable at the target definition instead of inferred from a global union. `section_privilege_test`
guards the mechanism itself.

---

## 7. Secrets

Passwords, private keys and certificate material never appear in an instance. They are resolved by
SecretManager, by **logical name**:

| Name | For |
|---|---|
| `database.password` | `database.connecting_role` |
| `database.admin_password` | `database.admin_role` |
| `database.ca_cert` | PEM for the CA the server certificate chains to |
| `database.client_cert` / `database.client_key` | mutual TLS |

Two properties matter:

**A component declares what it may read.** The manifest is checked *before* the provider is
consulted, so an undeclared name is an error about the manifest -- answering it, even to say "not
found", would tell a component whether a secret it may not have exists.

**The provider is chosen by the environment, not by the component.** `EnvironmentProvider.for_kind`
returns the environment provider for every deployed kind and the file store for `localhost`.

```rust
let secrets = SecretManager::new(
    EnvironmentProvider::for_kind(identity.kind()),
    Manifest::new([DATABASE_PASSWORD]),
);
let password = secrets.resolve(DATABASE_PASSWORD)?;
password.expose()          // the only way out, and greppable
```

```elixir
secrets = ServiceradarSecret.EnvironmentProvider.manager(kind, Manifest.new([Names.database_password()]))
{:ok, secret} = ServiceradarSecret.resolve(secrets, Names.database_password())
ServiceradarSecret.Secret.expose(secret)
```

### The variable transform

`EnvProvider` maps a logical name to a variable mechanically:

```
database.password        ->  SERVICERADAR_SECRET_DATABASE_PASSWORD
database.admin_password  ->  SERVICERADAR_SECRET_DATABASE_ADMIN_PASSWORD
a.b-c/d                  ->  SERVICERADAR_SECRET_A_B_C_D
```

`.`, `-` and `/` become `_`; the rest is ASCII-upcased. Mechanical rather than a mapping table,
because a table is a second place able to disagree with the manifest -- so a caller that knows the
name can *compute* the variable, and a `--test_env` list is derived rather than curated.

This is the shape the platform actually uses: `//helm/serviceradar` supplies every credential
through `valueFrom.secretKeyRef`, which is a Kubernetes Secret projected as an environment
variable, and a BuildBuddy workflow secret has no other form.

An **empty variable is absent, not an empty credential**. A set-but-blank secret authenticates as
nobody and produces a confusing error from the server instead of a clear one here.

A resolved `Secret` cannot be inspected. In Elixir the value lives in a closure rather than a
struct field, because a struct is a map on the BEAM and `inspect(term, structs: false)` would
otherwise print it straight through the `Inspect` protocol.

---

## 8. What guards this

`bazel test //config/...`

| Guard | Prevents |
|---|---|
| `protoc --encode` in the build rule | an unknown field or type mismatch reaching a loader |
| `round_trip_tests` | the compiled artifact differing from what was authored |
| `credential_shape_tests` | a password, key or DSN landing in an instance |
| `meta_rule_tests` | a schema field with no rule constraining it |
| `vector_tests` | a rule with no fixture that violates it (so deleting the rule fails a test) |
| `file_phase_tests` | a committed instance violating a file-phase rule -- the gate that makes the rule set real rather than a document |
| `predicate_law_tests` | a predicate breaking its algebraic law, or not being total |
| `section_privilege_test` | the section-scoped runfiles mechanism breaking |
| `binding_drift_*_test` | a committed binding differing from protoc's output |
| `ruleset_drift_test` (x3 languages) | an implementation validating against stale rules |
| `instance_drift_{ci,localhost}_test` | an embedded instance differing from its textproto |
| validator conformance (x3 languages) | the three engines disagreeing on the same input |

The drift tests exist because generated artifacts are committed so `cargo`, `mix` and `go` can
reach them without Bazel. A `diff_test` makes the committed copy and the generated one impossible
to disagree.

---

## 9. Recipes

**Add a field.**

1. Add it to `proto/config.proto` as `optional`.
2. Refresh the committed bindings -- **Elixir and Go only**. Rust's are produced by
   `proto_bindings/rust/build.rs` at build time and are not committed, so there is nothing to
   refresh and no drift test for them. The other two are committed so `mix` and `go` can reach
   them without Bazel, and a `diff_test` keeps the copy honest:
   ```
   bazel build //config/proto:config.generated.ex //config/proto:rules.generated.ex \
               //config/proto:config_go
   # copy each generated file over its committed counterpart under config/proto_bindings/
   bazel test //config/proto:all      # the four binding_drift_* tests must be green
   ```
3. Teach each language's field-path resolver the new path -- `field/2` in
   `manager_validator/{rust,elixir}` and its counterpart in `manager_validator/go`. All three are
   hand-written matches on the path string; an unhandled path is `unknown field path` at load.
4. Add at least one rule in `rules/ruleset.textproto` (`meta_rule_tests` requires it) and at least
   one fixture that violates it in `rules/fixtures/` (`vector_tests` requires it).
5. Set it in the instances that need it, then refresh the embedded `.binpb` copies that
   `instance_drift_*_test` compares against.

Expect the guards to catch you if you skip a step -- that is what they are for. Four of them
caught a mistake during the change that introduced `admin_role` and `ca_bundle_url`.

**Add an environment.** Add the kind to `EnvironmentKind`, add `environments/<kind>.textproto`,
add an `environment_config` target, and decide whether it is built-in or mounted (`Source`).

**Add a secret.** Add the logical name next to the others -- `secrets.rs` in Rust,
`ServiceradarSecret.Names` in Elixir -- declare it in the consuming component's manifest, and
provide it as `SERVICERADAR_SECRET_<NAME>`. Nothing else needs to change: the variable name is
computed from the logical name.

---

## 10. Known gaps

This system is being adopted incrementally. As of this writing:

- **Go has no environment provider.** `config/manager_secret/go` ships `FileProvider` only, so a
  Go service cannot resolve a secret from an environment variable yet, which is the only shape the
  platform actually supplies. Rust and Elixir have `EnvProvider`.
- **Nothing mounts `/etc/serviceradar/environment.binpb`.** No Helm template or compose file
  places an instance at the mount path, so the deployed kinds (`saas`, `demo`, `onprem`) have no
  instance to load today. Only `localhost` and `ci`, which carry theirs in the artifact, are
  exercised.
- **Adoption is partial.** `//rust/integration-db` and
  `//elixir/serviceradar_core:migrate_template` resolve through these managers; the Elixir
  integration shards still read `SRQL_TEST_*` through a bridge.

Tracked in `openspec/changes/add-unified-config-and-secret-managers`. Check that change's
`tasks.md` before assuming a phase is done.

---

## See also

- `config/SEMANTICS.md` -- the validation engine, formally
- `openspec/changes/add-unified-config-and-secret-managers/design.md` -- the decisions, including
  Decision 6 (section privilege), 9 (callable before the app tree starts), 10 (one tree) and
  12 (loading validates)
