# Integration-Test Environment Variable Inventory

> A ground-truth audit of every environment variable involved in running the database
> integration tests: what the code actually reads, what `.bazelrc` actually forwards, and where
> the two disagree. Derived mechanically from the source tree on 2026-08-17; every claim points
> at a `file:line`.

## TL;DR

```
.bazelrc forwards (database_env + nats_env) : 45 names
integration-test code reads                 : 58 names
read by code but NOT forwarded              : 26
forwarded but never read by that code       : 13
```

**The forwarding list and the readers are two independently hand-maintained lists, and they
match in neither direction.** Nothing links them, nothing validates them, and because nearly
every reader has a default, a *missing* forward does not fail — it silently takes the default.

This is the same failure shape as three other bugs found the same day (a skipped Go↔Rust interop
test, a manifest drift guard that never ran, an NTP corpus that compiled to zero fingerprints):
two or three lists that are supposed to agree, with no mechanism forcing them to.

---

## 1. Method

Readers were extracted by matching a retrieval API against a literal variable name across every
language in the tree (`.rs`, `.ex`, `.exs`, `.go`, `.py`, `.bzl`):

```
env::var / env::var_os          (Rust)
System.get_env / System.fetch_env(!)   (Elixir)
os.Getenv / os.LookupEnv        (Go)
os.environ / os.environ.get     (Python)
```

Mentions in `.bazelrc`, `buildbuddy.yaml`, workflows, shell scripts and docs are **not** counted
as readers — they are forwarders or documentation. The forwarded set is every
`test:database_env --test_env=` and `test:nats_env --test_env=` entry in `.bazelrc:81-129`.

"Integration-test code" means the files reachable from the database lifecycle and the suites it
provisions for:

- `rust/integration-db/src/lib.rs`, `rust/integration-db/tests/provision_db_test.rs`
- `integration_tests/srql/tests/support/harness.rs`, `rust/srql/src/config.rs`
- `elixir/serviceradar_core/test/db/{integration_env,template_env}.exs`
- `elixir/serviceradar_core/config/test.exs`
- `elixir/serviceradar_core/test/serviceradar/cluster/database_bootstrap_integration_test.exs`

---

## 2. The three-list problem

The environment contract is defined in **three independent places, with nothing linking them**:

| # | Definition site | Size | Maintained by |
|---|---|---|---|
| 1 | The readers (Rust + Elixir source) | 58 names | whoever writes a test |
| 2 | `.bazelrc` `database_env` / `nats_env` | 45 names | hand-edited union |
| 3 | `buildbuddy_setup_fixture_env.sh` | emits 5 | hand-edited script |

No layer validates another. Adding a reader does not add forwarding; deleting a reader does not
remove it. List 3 additionally *derives* two of its five values (`PGSSLSERVERNAME` and
`SRQL_TEST_DATABASE_SERVER_NAME`) and *rewrites* `sslmode=verify-full` into both DSNs, so a
credential that arrives straight from a secret store — the normal case — bypasses guarantees the
script was written to provide.

---

## 3. Inventory A — read by code, never forwarded (26)

These come from somewhere else, or silently take a default.

### 3.1 Consequential

| Variable | Read at | Consequence of not being forwarded |
|---|---|---|
| `SERVICERADAR_TEST_ADMIN_URL` | `rust/integration-db/src/lib.rs:288` | Fallback for `SRQL_TEST_ADMIN_URL`. Cannot fire **in a `bazel test` action** — but see §4.1, it is live under `bazel run`. |
| `SRQL_TEST_DATABASE_SSLMODE` | `config/test.exs:65` | TLS mode override, permanently inert. |
| `SERVICERADAR_TEST_DATABASE_SSLMODE` | `config/test.exs:64` | Alias of the above, equally inert. |
| `SRQL_TEST_DATABASE_SSL` / `_SSL_VERIFY` | `config/test.exs:76`, `:81` | TLS toggles, inert. |
| `SERVICERADAR_TEST_DATABASE_SSL` / `_SSL_VERIFY` | `config/test.exs:75`, `:80` | Aliases, inert. |
| `PGSSLTARGETNAME` | `rust/srql/src/config.rs:161` | The srql suite cannot receive a TLS target-name override. |
| `SRQL_FIXTURE_ROOT` | `integration_tests/srql/tests/support/harness.rs:729` | Fixture root override, inert. |

### 3.2 Near-miss naming

| Variable | Read at | Note |
|---|---|---|
| `SERVICERADAR_TEST_DB_SHARD` (singular) | `test/db/integration_env.exs:39` | Elixir side |
| `SERVICERADAR_TEST_DB_SHARDS` (plural) | `tests/provision_db_test.rs:46` | Rust side; **declared correctly** via `env = {}` in `rust/integration-db/BUILD.bazel:129` |

Two different variables, one letter apart, on two sides of the same lifecycle. The plural one is
the only variable in this whole inventory declared the right way — as a per-target `env` attribute
in the build graph rather than an ambient forward.

### 3.3 Inert tuning knobs

`*_POOL_SIZE`, `*_QUEUE_TARGET_MS`, `*_QUEUE_INTERVAL_MS`, `*_OWNERSHIP_TIMEOUT_MS`,
`*_URL_FILE` — each in both the `SRQL_` and `SERVICERADAR_` spelling
(`config/test.exs:59-60, 167-172, 175-176, 179-180`), plus `CNPG_SEARCH_PATH`
(`config/test.exs:186`), `CNPG_APP_USER` and `CNPG_APP_PASSWORD`
(`startup_migrations.ex:213`, `:235`).

---

## 4. Inventory B — forwarded, not read by integration code (13)

> **These are NOT safe to delete.** An earlier draft of this note called them dead; adversarial
> verification refuted that on three separate grounds, recorded below. "Forwarded but unread by
> the integration suites" is the accurate framing — *provisioned but not yet consumed*.

| Variable | Status |
|---|---|
| `NATS_CA_FILE`, `NATS_CERT_FILE`, `NATS_KEY_FILE` | No reader under these names. But they are a **live documented interface** — `k8s/sr-testing/export-nats-env.sh:27-29` emits exactly these names and `k8s/sr-testing/README.md:62-64` prescribes forwarding them to `bazel test`. See §4.2 for the naming drift. |
| `NATS_CA_B64`, `NATS_CERT_B64`, `NATS_KEY_B64` | No reader. `NATS_KEY_B64` **was** pinned by a committed test; that test is deleted, so the pin is gone — see §4.1. |
| `NATS_URL`, `NATS_SERVER_NAME` | Read by `config/runtime.exs` (evaluated under `mix test`) and by Go production code. Not dead. |
| `TEST_CNPG_HOST/PORT/DATABASE/USERNAME/PASSWORD` | Read by `elixir/web-ng/config/test.exs`; web-ng is genuinely not selected by the database step — `TEST_CNPG_PASSWORD` **was** pinned by the same now-deleted test. |

### 4.1 The drift guard that existed has been DELETED

> **Superseded.** `buildbuddy_cache_proxy_config_test.py` was removed from the repository. Read
> the rest of this section as history: it records what the guard asserted, which is what a
> replacement has to cover. Nothing enforces any of it today.
>
> Two things had already broken it before the deletion, and both are worth carrying forward as
> warnings. It had **no `py_test` target**, so `make test` never ran it despite this section
> claiming it did; and its `setUp` read `.github/workflows/elixir-integration-sr-core.yml`, a
> path deleted in 8ce61b5a0d, so every test in it errored rather than asserted. A guard that is
> not a build target is not a guard.

It was an untagged `py_test` that took **`.bazelrc` as a data dependency** and asserted its
contents, encoding the forwarding list as an invariant:

```
buildbuddy_cache_proxy_config_test.py:216   assert "--test_env=NATS_KEY_B64" in test:nats_env
buildbuddy_cache_proxy_config_test.py:217   assert "test:database_env --config=nats_env"
buildbuddy_cache_proxy_config_test.py:202   assert NATS_KEY_B64 NOT in the global `test ` profile
                                            (same shape for TEST_CNPG_PASSWORD)
```

Deleting any of those `.bazelrc` lines *would have* turned this test red. So the repo no longer has a
drift guard — but it checks the forwarding list **against itself** (opt-in placement: present in
`database_env`/`nats_env`, absent from the global `test` profile). Nothing checks the forwarding
list against **the set of names the code actually reads**. That is the missing half, and it is
why the two lists diverged to 26/13 without anything going red.

### 4.2 The NATS variables are a naming-drift artifact, not residue

The Go NATS clients read the **un-underscored** spellings:

```
go/pkg/k8sinventory/config.go:82-84    NATS_CACERTFILE   NATS_CERTFILE   NATS_KEYFILE
go/pkg/trivysidecar/config.go:64-66    NATS_CACERTFILE   NATS_CERTFILE   NATS_KEYFILE
```

`.bazelrc:124-129` forwards `NATS_CA_FILE`, `NATS_CERT_FILE`, `NATS_KEY_FILE`. **These two sets
will never meet.** Separately, the one NATS-mTLS Elixir test
(`test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs:57,76-84`) was written against a third
family — `NATS_TEST_HOST`, `NATS_TEST_PORT`, `NATS_TEST_CERT_DIR`, `NATS_TEST_SERVER_NAME`.

Three spellings of the same concept, in three languages, none of which is what CI forwards. This
is the §5 aliasing problem in its purest form.

### 4.3 `SERVICERADAR_TEST_ADMIN_URL` is live under `bazel run`

`--test_env` governs `TestRunner` actions only. `//rust/integration-db:prepare_template` is a
`rust_binary` invoked with `bazel run` (`buildbuddy.yaml:276-277`,
`.agents/skills/srql-fixtures-db-tests/SKILL.md:140`), which launches the binary in the **Bazel
client's ambient environment** — no forwarding declaration involved. Its path
`prepare_template.rs:45` → `template.rs:100` → `admin_url()` reaches the fallback at
`lib.rs:288`.

The decisive proof that the path is live: `buildbuddy.yaml:266` **explicitly unsets it**
immediately before that `bazel run`:

```
unset SERVICERADAR_TEST_DATABASE_URL SERVICERADAR_TEST_ADMIN_URL
```

That line only makes sense if the value would otherwise be inherited. And
`scripts/srql-fixture-env.sh:184` exports `SERVICERADAR_TEST_ADMIN_URL` while never exporting
`SRQL_TEST_ADMIN_URL` at all — so for a developer sourcing that file, `lib.rs:288` is the *only*
resolution path.

---

## 5. The aliasing problem

`elixir/serviceradar_core/config/test.exs` reads **fourteen pairs** of variables that differ only
in prefix, on adjacent lines:

```
:57  SERVICERADAR_TEST_DATABASE_URL        :58  SRQL_TEST_DATABASE_URL
:59  SERVICERADAR_TEST_DATABASE_URL_FILE   :60  SRQL_TEST_DATABASE_URL_FILE
:64  SERVICERADAR_TEST_DATABASE_SSLMODE    :65  SRQL_TEST_DATABASE_SSLMODE
:75  SERVICERADAR_TEST_DATABASE_SSL        :76  SRQL_TEST_DATABASE_SSL
:80  SERVICERADAR_TEST_DATABASE_SSL_VERIFY :81  SRQL_TEST_DATABASE_SSL_VERIFY
:110 SERVICERADAR_TEST_DATABASE_CA_CERT    :111 SRQL_TEST_DATABASE_CA_CERT
:122 SERVICERADAR_..._CA_CERT_FILE         :123 SRQL_..._CA_CERT_FILE
:127 SERVICERADAR_TEST_DATABASE_CERT       :128 SRQL_TEST_DATABASE_CERT
:132 SERVICERADAR_TEST_DATABASE_KEY        :133 SRQL_TEST_DATABASE_KEY
:137 SERVICERADAR_..._SERVER_NAME          :138 SRQL_..._SERVER_NAME
:167 SERVICERADAR_..._POOL_SIZE            :168 SRQL_..._POOL_SIZE
:171 SERVICERADAR_..._QUEUE_TARGET_MS      :172 SRQL_..._QUEUE_TARGET_MS
:175 SERVICERADAR_..._QUEUE_INTERVAL_MS    :176 SRQL_..._QUEUE_INTERVAL_MS
:179 SERVICERADAR_..._OWNERSHIP_TIMEOUT_MS :180 SRQL_..._OWNERSHIP_TIMEOUT_MS
```

Add the `CNPG_*` family, which covers the same concepts again for production and dev
(`CNPG_SSL_MODE`, `CNPG_CERT_DIR`, `CNPG_CA_FILE`, `CNPG_TLS_SERVER_NAME`, …), and one logical
setting has **up to three valid spellings** with no canonical one. A reader takes whichever is
set; a forwarder must guess which one the caller used. That is why the forwarding list is a
union, and why it can only ever grow.

---

## 6. Full call-site inventory

### 6.1 Fixture core — the values that must be right

| Variable | Call sites |
|---|---|
| `SRQL_TEST_DATABASE_URL` | `rust/integration-db/src/lib.rs:157`, `:269`; `config/test.exs:58`; `test/db/integration_env.exs:53`; `test/db/template_env.exs:15` |
| `SRQL_TEST_ADMIN_URL` | `rust/integration-db/src/lib.rs:287`; `database_bootstrap_integration_test.exs:43` |
| `SRQL_TEST_DATABASE_CA_CERT` | `rust/integration-db/src/lib.rs:406`; `harness.rs:948`; `config/test.exs:111`; `database_bootstrap_integration_test.exs:600` |
| `SERVICERADAR_TEST_DATABASE_OWNER` | `rust/integration-db/src/lib.rs:264` |
| `GITHUB_RUN_ID` / `GITHUB_RUN_ATTEMPT` | `rust/integration-db/src/lib.rs:102`; `test/db/integration_env.exs:22-23` |

### 6.2 libpq-style TLS

| Variable | Call sites |
|---|---|
| `PGSSLROOTCERT` | `rust/integration-db/src/lib.rs:412`; `rust/srql/src/config.rs:156`; `harness.rs:938`; `database_bootstrap_integration_test.exs:427` |
| `PGSSLSERVERNAME` | `rust/integration-db/src/lib.rs:444`; `rust/srql/src/config.rs:159` |
| `PGSSLCERT` | `rust/srql/src/config.rs:157`; `harness.rs:804` |
| `PGSSLKEY` | `rust/srql/src/config.rs:158`; `harness.rs:805` |
| `PGSSLTARGETNAME` | `rust/srql/src/config.rs:161` *(not forwarded)* |

### 6.3 Go call sites — eight, none of them tests

Go reads **eight** of these variables, all in two production config loaders
(`LoadConfigFromEnv`), none in a test:

| Variable | Call sites | Forwarded by `.bazelrc`? |
|---|---|---|
| `NATS_SERVER_NAME` | `go/pkg/k8sinventory/config.go:85`, `go/pkg/trivysidecar/config.go:67` | yes |
| `NATS_CACERTFILE` | `k8sinventory/config.go:82`, `trivysidecar/config.go:64` | **no** — `.bazelrc` forwards `NATS_CA_FILE` |
| `NATS_CERTFILE` | `k8sinventory/config.go:83`, `trivysidecar/config.go:65` | **no** — `.bazelrc` forwards `NATS_CERT_FILE` |
| `NATS_KEYFILE` | `k8sinventory/config.go:84`, `trivysidecar/config.go:66` | **no** — `.bazelrc` forwards `NATS_KEY_FILE` |

A broad sweep of `.go` files for the literal names — which would also catch `envconfig` struct
tags or a config library resolving the name indirectly — returns these same eight and nothing
else. **No Go integration test reads any forwarded variable**: the `database_env` / `nats_env`
profiles exist for Rust and Elixir only.

### 6.4 `CNPG_*` — mostly production and dev, not the fixture

`CNPG_HOST/PORT/DATABASE/USERNAME/PASSWORD/SSL_MODE/CERT_DIR/CA_FILE/CERT_FILE/KEY_FILE/TLS_SERVER_NAME`
are read overwhelmingly by **non-test** code: `startup_migrations.ex`,
`serviceradar_core_elx/config/runtime.exs`, and `web-ng/config/{dev,runtime,test}.exs`. Within the
integration suites they appear only in `config/test.exs` and
`database_bootstrap_integration_test.exs`. `CNPG_ADMIN_USERNAME` / `CNPG_ADMIN_PASSWORD` have
exactly one reader each (`startup_migrations.ex:1489`, `:1492`), both production code.

---

## 7. The minimal set

Split by **secret vs. configuration** — only the first genuinely needs ambient forwarding.

**Genuinely secret (3).** Carry passwords or rotating material; must stay runtime-only and out of
the build graph and cache keys:

```
SRQL_TEST_DATABASE_URL
SRQL_TEST_ADMIN_URL
SRQL_TEST_DATABASE_CA_CERT
```

**Run identity (2).** Not secret, but per-invocation: `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`.
These select the disposable database name and could be passed as `--test_env=NAME=VALUE`.

**Everything else is configuration.** Server names, sslmode, pool sizes, shard ids, cert
directories, search paths — none is secret, so all of it belongs in the build graph as per-target
`env = {}`, the way `SERVICERADAR_TEST_DB_SHARDS` already is
(`rust/integration-db/BUILD.bazel:129`).

---

## 8. Recommendations

1. **Build a drift guard — there is no longer one to extend.** `buildbuddy_cache_proxy_config_test.py`
   is deleted (§4.1), and before that it was an orphan with no Bazel target whose every test
   errored in `setUp`. Its replacement must be a real Bazel test target, per the repository's
   rule that everything is a target, and must assert BOTH directions: every name in
   `database_env`/`nats_env` is read somewhere, and every name the integration suites read is
   forwarded or declared in a target `env`. Without it, any cleanup below rots exactly the way
   this list did — and the way the guard itself did.
2. **Reconcile the NATS names before touching them.** Do not delete the six — one is pinned by
   the test above and the `*_FILE` trio is a live `k8s/sr-testing` interface (§4.1, §4.2). The
   real defect is three spellings of one concept (`NATS_CA_FILE` forwarded, `NATS_CACERTFILE`
   read by Go, `NATS_TEST_*` used by the Elixir e2e test). Pick one family, update all three
   sides plus the pinning test, then drop what is genuinely unreferenced.
3. **Move non-secret configuration into per-target `env = {}`.** This is what shrinks the
   forwarding list from 45 to ~5 and makes each target's requirements readable at its definition.
4. **Collapse the three naming schemes to one.** Fourteen alias pairs plus the `CNPG_*` family is
   the root cause of the union; until it is one name per concept, the forwarding list can only grow.
5. **Then retire `buildbuddy_setup_fixture_env.sh`.** Its two load-bearing jobs are forcing
   `sslmode=verify-full` and deriving the TLS server name. The first is now enforced in code
   (`require_verified_tls`, `rust/integration-db/src/lib.rs`), and the second is a non-secret
   constant that can be a stored secret or a target `env`.

### Sequencing

Do not do 2–5 in one change. Each removes a variable that something might read through a path
this audit did not model (a dynamically constructed name, a `runtime.exs` evaluated under
`mix test`, a `bazel run` target inheriting the ambient environment). With the guard from step 1
in place, each subsequent step fails loudly and specifically instead of producing a database
connection that silently uses a default.

---

## Appendix — verification record

This inventory is derived from static reads (`env::var`, `System.get_env`, `os.Getenv`,
`os.environ`, Bazel `env = {}`). Three of its riskiest claims were put through independent
adversarial review, and **two of the three original claims were wrong**:

| Original claim | Verdict | Correction |
|---|---|---|
| Six NATS vars are dead and deletable | **partly restored** | The `*_FILE` trio remains a live `k8s/sr-testing` interface (§4.2), so the claim is still wrong for those. But `NATS_KEY_B64`'s only pin was `buildbuddy_cache_proxy_config_test.py`, now deleted — it has no reader and no pin, so it IS deletable. |
| `SERVICERADAR_TEST_ADMIN_URL` can never fire under Bazel | **refuted** | True for `bazel test` actions only; live under `bazel run prepare_template`, which CI actively `unset`s (§4.3) |
| `TEST_CNPG_*` are unused noise in the DB step | **partly restored** | The tag-filter observation holds. `TEST_CNPG_PASSWORD`'s only pin was the same deleted test, so it is no longer pinned; `elixir/web-ng/config/test.exs` remains the live reader of the family. |

Every correction was confirmed against the source before being written here. The pattern in all
three: a static read-scan does not see values consumed by `bazel run` targets, by tests that
assert on configuration files, or under a different spelling. **Treat every "unused" entry in
this note as a lead to investigate, not a licence to delete.**
