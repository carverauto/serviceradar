# Elixir environment inventory, substitution plan and migration plan

Companion to `design.md` and `tasks.md`. Produced for phase 7 (Elixir) after the
first two counts of this surface disagreed. It exists because the stated goal is
**zero environment reads in Elixir**, and that goal cannot be planned against a
count -- it needs a per-name destination.

## 1. Method

Scanned every `elixir/**/*.ex` and `*.exs` outside `deps/`, `_build/`,
`node_modules/`, `.elixir_ls/` and `cover/` -- 3943 files. Five read forms are
counted, because the first two passes over this surface each missed one and each
produced a different number:

| form | why a naive scan misses it |
|---|---|
| `System.get_env("NAME")` / `fetch_env!` | -- |
| `"NAME" \|> System.get_env("default")` | the name is BEFORE the call; a scan for `get_env("` reads the DEFAULT as the name |
| `helper("NAME", ...)` for 25 verified wrappers | the name is an argument to a project helper, not to `System` |
| `"NAME" \|> helper()` | both problems at once |
| `System.get_env(var)` | the name is not a literal at all -- unresolvable statically |

The 25 wrappers were not guessed. Each is a `def`/`defp` whose first parameter
reaches `System.get_env`, confirmed by finding call sites that pass a literal
`[A-Z][A-Z0-9_]*` name: `parse_int_env`, `enabled?`, `read_secret_env`, `env_int`,
`parse_bool`, `fetch`, `parse_queue_limit`, `parse_optional_int_env`, `cold_window`,
`env`, `positive_int_env`, `cold_parse_int`, `configured_positive_integer`,
`load_positive_int`, `required_env`, `cold_secret_env`, `env_bool`, `load_flow_int`,
`read_interval`, `env_true?`, `env_integer`, `require_env`, `otx_env`, `env_float`,
`get_env_nonempty`.

This matters beyond arithmetic: **four secrets are only reachable through a wrapper**
-- `SECRET_KEY_BASE`, `EDGE_ONBOARDING_ENCRYPTION_KEY`, `PLUGIN_STORAGE_SIGNING_SECRET`
and `SERVICERADAR_EDGE_CRYPTO_SECRET` are all read as
`read_secret_env.("NAME", "NAME_FILE")`. Any exit criterion that greps for
`get_env("` will report those four as already migrated while they are not.

## 2. Totals

| measure | count |
|---|---|
| read sites | **1173** |
| ... resolvable to a literal name | 1082 |
| ... name computed at runtime | 91 |
| write sites (`put_env` / `delete_env` / test `with_env`) | 131 |
| distinct names | **676** |

| category | names | read sites |
|---|---|---|
| secret | 45 | 94 |
| material | 22 | 55 |
| schema | 58 | 127 |
| unschemad | 545 | 797 |
| platform | 6 | 9 |

| application | read sites |
|---|---|
| `serviceradar_core` | 593 |
| `web-ng` | 321 |
| `serviceradar_core_elx` | 167 |
| `serviceradar_agent_gateway` | 90 |
| `serviceradar_srql` | 2 |

`schema` means the value is already modelled by `config/proto/config.proto` as it
stands today. `unschemad` means the schema has no field for it yet -- that is the
gap between "phase 7 converts the covered reads" and "zero environment reads".

## 3. Where these values come from

They are not set by Bazel. Bazel names two of them. The source is Helm:

| mechanism | names it actually sets |
|---|---|
| helm | 301 |
| scripts | 35 |
| ci-legacy | 8 |
| docker | 8 |
| bazel | 2 |
| **nothing in this repository** | **350** |

Counting only real assignments -- a Helm `- name: FOO` under `env:`, a compose
`FOO:`/`FOO=`, a `Dockerfile` `ENV FOO`, an `export FOO=` in a script, a
`--test_env=FOO` in a Bazel invocation. Incidental mentions in prose are excluded.

| Helm template | names it sets |
|---|---|
| `helm/serviceradar/templates/core.yaml` | 186 |
| `helm/serviceradar/templates/web.yaml` | 138 |
| `helm/serviceradar/templates/agent-gateway.yaml` | 53 |
| `helm/serviceradar/templates/core-migrations-job.yaml` | 42 |
| `helm/serviceradar/templates/datasvc.yaml` | 2 |
| `helm/serviceradar/templates/_helpers.tpl` | 1 |
| `helm/serviceradar/templates/k8s-inventory.yaml` | 1 |
| `helm/serviceradar/templates/trivy-sidecar.yaml` | 1 |

The Helm count includes the `extraEnv:` maps in `values-demo.yaml` and
`values-tenant.yaml`, which set nine names as `NAME: value` rather than as a
`- name: NAME` list entry. Counting only the list form put the never-set number nine
too high in the first pass of this document.

### 3.1 What happens when a never-set variable is absent

It is worth being exact about this, because "set nowhere" and "fails loudly" are
different claims. Of the 350 never-set names, 346 have at least one read
site; the rest appear only in `put_env`/`delete_env`. Measured at every read site of
those 346:

| behaviour when absent | names |
|---|---|
| `nil` reaches the caller | 169 |
| a literal default in the source is used | 132 |
| another environment name is tried instead | 39 |
| the process raises | 6 |

**Six names raise. The other 340 do not fail at all** -- they configure something
differently and say nothing. The six that raise are `SERVICERADAR_ARMIS_API_URL`,
`SERVICERADAR_ARMIS_API_SECRET`, `SERVICERADAR_ARMIS_DEVICE_IP`,
`SERVICERADAR_ARMIS_CUSTOM_FIELD`, `NATS_TEST_HOST` and `NATS_TEST_CERT_DIR`, all in
tests that are meant to be skipped unless deliberately configured.

`nil` reaching the caller is not one behaviour. It is at least three, and all three
are silent:

- **A feature turns itself off.** `CLUSTER_GOSSIP_SECRET` is unset, so
  `if gossip_secret do` is false and the gossip clustering strategy is simply not
  configured ([elixir/serviceradar_agent_gateway/config/runtime.exs:271](elixir/serviceradar_agent_gateway/config/runtime.exs#L271)).
- **A credential becomes absent rather than wrong.** `AGENT_GATEWAY_NATS_USER` is
  passed straight through as `user: nil` into the NATS connection
  ([elixir/serviceradar_agent_gateway/config/runtime.exs:435](elixir/serviceradar_agent_gateway/config/runtime.exs#L435)).
- **An empty value substitutes for a real one.** `SERVICERADAR_HOSTED_CLUSTER_CONTRACT`
  unset decodes to `%{}`
  ([elixir/serviceradar_agent_gateway/config/runtime.exs:146](elixir/serviceradar_agent_gateway/config/runtime.exs#L146)).

Whole subsystems are configured this way. The cold tier reads 31 names of which 25
resolve to `nil`, so `config :serviceradar_core, :cold_tier` is a keyword list of
nils -- host, database, S3 credentials, FDW password -- assembled without complaint
at every boot ([elixir/serviceradar_core/config/runtime.exs:420-434](elixir/serviceradar_core/config/runtime.exs#L420-L434)).
Plugin storage is the same shape: 12 names, all `nil`, no default and no error.

**33 of the never-set names are credentials.** None of them raises when missing
except `NATS_TEST_CERT_DIR`. That includes `CLUSTER_GOSSIP_SECRET`,
`SERVICERADAR_COLD_TIER_S3_SECRET_ACCESS_KEY`, `SERVICERADAR_PROXMOX_API_TOKEN`,
`ADMIN_BASIC_AUTH_PASSWORD` and every `*_PASSWORD_FILE` variant.

This is the strongest argument in this document for the whole change. A schema with
explicit presence and a validator that rejects a missing field converts all
301 of these (169 silent `nil` plus 132 silent default) from a
behaviour change nobody sees into a boot-time error naming the field.

Two consequences for the plan:

- **Task 8 is not optional and it is not small.** 301 names are supplied by
  four Helm templates. Converting an Elixir read without deleting the matching Helm
  `env:` entry leaves a value that is set and ignored, which is worse than either end
  state because the manifest still documents a control that no longer controls anything.
- **350 of 676 names are set nowhere in this repository.** They are read with a
  default and never supplied -- dead knobs, or knobs an operator is expected to know
  about from source. Each is a decision, not a migration: give it a schema field with
  the default it already has, or delete the read. Deleting is cheaper and is the
  default recommendation for anything in this set with a single call site.

## 4. Similarity: names that differ but mean the same value

Two independent checks. The second is the one that carries weight.

### 4.1 Proven by usage (fallback chains)

A value read as `get_env(A) || get_env(B)` proves A and B are the same value: one
expression, one destination, B is the older spelling. This is not a heuristic.
There are **63 such pairs**, collapsing into the groups below. Each group
becomes ONE field or ONE secret name.

| group | names (reads) | evidence |
|---|---|---|
| **CNPG_CA_FILE** | `CNPG_CA_FILE` (4) <br> `PGSSLROOTCERT` (1) <br> `SERVICERADAR_TEST_DATABASE_CA_CERT` (2) <br> `SERVICERADAR_TEST_DATABASE_CA_CERT_FILE` (2) <br> `SRQL_TEST_DATABASE_CA_CERT` (2) <br> `SRQL_TEST_DATABASE_CA_CERT_FILE` (2) | `elixir/serviceradar_core/config/test.exs:110` |
| **CNPG_PASSWORD** | `CNPG_APP_PASSWORD` (2) <br> `CNPG_APP_PASSWORD_FILE` (2) <br> `CNPG_PASSWORD` (12) <br> `CNPG_PASSWORD_FILE` (5) | `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex:233` |
| **SRQL_TEST_DATABASE_URL** | `SERVICERADAR_TEST_DATABASE_URL` (2) <br> `SERVICERADAR_TEST_DATABASE_URL_FILE` (1) <br> `SRQL_TEST_DATABASE_URL` (3) <br> `SRQL_TEST_DATABASE_URL_FILE` (1) | `elixir/serviceradar_core/config/test.exs:57` |
| **CNPG_CERT_FILE** | `CNPG_CERT_FILE` (4) <br> `SERVICERADAR_TEST_DATABASE_CERT` (2) <br> `SRQL_TEST_DATABASE_CERT` (2) | `elixir/serviceradar_core/config/test.exs:127` |
| **CNPG_KEY_FILE** | `CNPG_KEY_FILE` (4) <br> `SERVICERADAR_TEST_DATABASE_KEY` (2) <br> `SRQL_TEST_DATABASE_KEY` (2) | `elixir/serviceradar_core/config/test.exs:132` |
| **CNPG_SSL_MODE** | `CNPG_SSL_MODE` (9) <br> `SERVICERADAR_TEST_DATABASE_SSLMODE` (2) <br> `SRQL_TEST_DATABASE_SSLMODE` (2) | `elixir/serviceradar_core/config/test.exs:63` |
| **CNPG_TLS_SERVER_NAME** | `CNPG_TLS_SERVER_NAME` (8) <br> `SERVICERADAR_TEST_DATABASE_SERVER_NAME` (2) <br> `SRQL_TEST_DATABASE_SERVER_NAME` (2) | `elixir/serviceradar_core/config/test.exs:137` |
| **CNPG_USERNAME** | `CNPG_APP_USER` (1) <br> `CNPG_USERNAME` (7) <br> `CNPG_USERNAME_FILE` (1) | `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex:213` |
| **NATS_URL** | `AGENT_GATEWAY_NATS_URL` (1) <br> `NATS_URL` (5) <br> `SERVICERADAR_NATS_URL` (1) | `elixir/serviceradar_agent_gateway/config/runtime.exs:410` |
| **SERVICERADAR_EDGE_CRYPTO_SECRET** | `EDGE_ONBOARDING_ENCRYPTION_KEY` (4) <br> `SERVICERADAR_EDGE_CRYPTO_SECRET` (5) <br> `SERVICERADAR_RECORDING_INTEGRITY_SECRET` (1) | `elixir/serviceradar_agent_gateway/config/runtime.exs:43` |
| **AGENT_GATEWAY_ICMP_METRICS_ENABLED** | `AGENT_GATEWAY_ICMP_METRICS_ENABLED` (1) <br> `AGENT_GATEWAY_ICMP_METRICS_SHADOW_ENABLED` (1) | `elixir/serviceradar_agent_gateway/config/runtime.exs:335` |
| **AGE_GRAPH_NAME** | `AGE_GRAPH_NAME` (2) <br> `SERVICERADAR_AGE_GRAPH_NAME` (2) | `elixir/serviceradar_core/config/runtime.exs:526` |
| **BASE_URL** | `BASE_URL` (2) <br> `SERVICERADAR_NORTHBOUND_CALLBACK_BASE_URL` (2) | `elixir/web-ng/config/runtime.exs:1617` |
| **CLOAK_KEY** | `CLOAK_KEY` (3) <br> `CLOAK_KEY_FILE` (3) | `elixir/serviceradar_core/lib/serviceradar/vault.ex:48` |
| **CNPG_ADMIN_PASSWORD** | `CNPG_ADMIN_PASSWORD` (1) <br> `CNPG_ADMIN_PASSWORD_FILE` (1) | `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex:1491` |
| **CNPG_ADMIN_USERNAME** | `CNPG_ADMIN_USERNAME` (1) <br> `CNPG_ADMIN_USERNAME_FILE` (1) | `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex:1488` |
| **CONTROL_PLANE_PUBLIC_KEY** | `CONTROL_PLANE_PUBLIC_KEY` (1) <br> `CONTROL_PLANE_PUBLIC_KEY_FILE` (1) | ``_FILE` duality` |
| **CORE_ADDRESS** | `CORE_ADDRESS` (1) <br> `SERVICERADAR_CORE_ADDRESS` (1) | `elixir/web-ng/config/runtime.exs:1664` |
| **DATASVC_CERT_DIR** | `DATASVC_CERT_DIR` (4) <br> `DATASVC_SPIFFE_CERT_DIR` (2) | `elixir/serviceradar_core/lib/serviceradar/nats/account_client.ex:538` |
| **EVENT_WRITER_FLOW_EXTRA_SUBJECTS** | `EVENT_WRITER_FLOW_DRAIN_EXTRA_SUBJECTS` (1) <br> `EVENT_WRITER_FLOW_EXTRA_SUBJECTS` (1) | `elixir/serviceradar_core/lib/serviceradar/event_writer/config.ex:628` |
| **GEOLITE_MMDB_DOWNLOAD_ENABLED** | `GEOLITE_MMDB_DOWNLOAD_ENABLED` (1) <br> `GEOLITE_MMDB_SCHEDULER_ENABLED` (1) | `elixir/serviceradar_core/lib/serviceradar/observability/geolite_mmdb_download_worker.ex:208` |
| **GITHUB_TOKEN** | `GH_TOKEN` (2) <br> `GITHUB_TOKEN` (3) | `elixir/web-ng/lib/serviceradar_web_ng/edge/release_source_importer.ex:389` |
| **RUSTLER_TMPDIR** | `RUSTLER_TEMP_DIR` (2) <br> `RUSTLER_TMPDIR` (3) | `elixir/serviceradar_srql/lib/serviceradar_srql/native.ex:17` |
| **SECRET_KEY_BASE** | `DEV_SECRET_KEY_BASE` (1) <br> `SECRET_KEY_BASE` (2) | `elixir/web-ng/config/dev.exs:207` |
| **SERVICERADAR_ADMIN_PASSWORD** | `SERVICERADAR_ADMIN_PASSWORD` (1) <br> `SERVICERADAR_ADMIN_PASSWORD_FILE` (1) | ``_FILE` duality` |
| **SERVICERADAR_API_KEY** | `SERVICERADAR_API_KEY` (2) <br> `SERVICERADAR_API_KEYS` (1) | `elixir/web-ng/config/runtime.exs:201` |
| **SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD** | `SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD` (2) <br> `SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD_FILE` (1) | ``_FILE` duality` |
| **SERVICERADAR_FIRST_PARTY_PLUGIN_COSIGN_PUBLIC_KEY** | `SERVICERADAR_FIRST_PARTY_PLUGIN_COSIGN_PUBLIC_KEY` (1) <br> `SERVICERADAR_FIRST_PARTY_PLUGIN_COSIGN_PUBLIC_KEY_FILE` (1) | ``_FILE` duality` |
| **SERVICERADAR_MAILER_ADAPTER** | `SERVICERADAR_CORE_MAILER_ADAPTER` (1) <br> `SERVICERADAR_MAILER_ADAPTER` (1) | `elixir/web-ng/config/runtime.exs:1786` |
| **SERVICERADAR_MAX_DEVICES** | `SERVICERADAR_MANAGED_DEVICE_LIMIT` (1) <br> `SERVICERADAR_MAX_DEVICES` (2) | `elixir/web-ng/config/runtime.exs:766` |
| **SPIFFE_WORKLOAD_API_SOCKET** | `SPIFFE_ENDPOINT_SOCKET` (1) <br> `SPIFFE_WORKLOAD_API_SOCKET` (4) | `elixir/serviceradar_core/config/runtime.exs:516` |
| **SRQL_TEST_ADMIN_URL** | `SERVICERADAR_TEST_ADMIN_URL` (1) <br> `SRQL_TEST_ADMIN_URL` (1) | `elixir/serviceradar_core/test/serviceradar/cluster/database_bootstrap_integration_test.exs:42` |
| **SRQL_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS** | `SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS` (1) <br> `SRQL_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS` (1) | `elixir/serviceradar_core/config/test.exs:179` |
| **SRQL_TEST_DATABASE_POOL_SIZE** | `SERVICERADAR_TEST_DATABASE_POOL_SIZE` (1) <br> `SRQL_TEST_DATABASE_POOL_SIZE` (1) | `elixir/serviceradar_core/config/test.exs:167` |
| **SRQL_TEST_DATABASE_QUEUE_INTERVAL_MS** | `SERVICERADAR_TEST_DATABASE_QUEUE_INTERVAL_MS` (1) <br> `SRQL_TEST_DATABASE_QUEUE_INTERVAL_MS` (1) | `elixir/serviceradar_core/config/test.exs:175` |
| **SRQL_TEST_DATABASE_QUEUE_TARGET_MS** | `SERVICERADAR_TEST_DATABASE_QUEUE_TARGET_MS` (1) <br> `SRQL_TEST_DATABASE_QUEUE_TARGET_MS` (1) | `elixir/serviceradar_core/config/test.exs:171` |
| **SRQL_TEST_DATABASE_SSL** | `SERVICERADAR_TEST_DATABASE_SSL` (1) <br> `SRQL_TEST_DATABASE_SSL` (1) | `elixir/serviceradar_core/config/test.exs:75` |
| **SRQL_TEST_DATABASE_SSL_VERIFY** | `SERVICERADAR_TEST_DATABASE_SSL_VERIFY` (1) <br> `SRQL_TEST_DATABASE_SSL_VERIFY` (1) | `elixir/serviceradar_core/config/test.exs:80` |
| **VULNCHECK_API_TOKEN** | `SERVICERADAR_VULNCHECK_TOKEN` (1) <br> `VULNCHECK_API_TOKEN` (1) | `elixir/serviceradar_core/lib/serviceradar/inventory/advisory_feeds/config.ex:122` |

Highlights a lexical check cannot find:

- `GH_TOKEN` = `GITHUB_TOKEN`
- `SPIFFE_ENDPOINT_SOCKET` = `SPIFFE_WORKLOAD_API_SOCKET`
- `SERVICERADAR_MANAGED_DEVICE_LIMIT` = `SERVICERADAR_MAX_DEVICES`
- `SERVICERADAR_VULNCHECK_TOKEN` = `VULNCHECK_API_TOKEN`
- `BASE_URL` = `SERVICERADAR_NORTHBOUND_CALLBACK_BASE_URL`
- `CNPG_CA_FILE` = `PGSSLROOTCERT` = `SERVICERADAR_TEST_DATABASE_CA_CERT_FILE` = `SRQL_TEST_DATABASE_CA_CERT_FILE`
- a three-way secret: `SERVICERADAR_RECORDING_INTEGRITY_SECRET` = `SERVICERADAR_EDGE_CRYPTO_SECRET` = `EDGE_ONBOARDING_ENCRYPTION_KEY`

One pair was rejected after reading the code: `SERVICERADAR_REQUIRE_DB_TESTS or CI`
is a disjunction of two different facts, not an alias.

Two more are aliases with a transform rather than plain fallbacks, and are listed
as aliases deliberately -- the underlying value is one value:

- `CNPG_APP_USER || sanitize_app_user(CNPG_USERNAME)` -- same role, one spelling sanitised
- `AGENT_GATEWAY_ICMP_METRICS_ENABLED || AGENT_GATEWAY_ICMP_METRICS_SHADOW_ENABLED` -- rename, old name still honoured

### 4.2 Suggested by spelling only (not yet proven)

Same check with prefixes, `_FILE`/`_PATH` suffixes and known synonyms
(`CACERT`/`CA_CERT`/`CA_FILE`, `ADDRESS`/`ADDR`, `URI`/`ENDPOINT`/`URL`,
`USER`/`USERNAME`, `DB`/`DATABASE`, `SECS`/`SECONDS`, `MILLIS`/`MS`) normalised away,
then grouped on the remaining token SET so word order does not matter. Groups already
proven above are omitted. These need a human read before collapsing -- scope prefixes
sometimes carry real meaning (`CONTROL_DATABASE_*` is a genuinely different database
from `DATABASE_*`).

| normalised | names |
|---|---|
| `DATABASE_URL` | `DATABASE_URL`, `SERVICERADAR_TEST_DATABASE_URL`, `SERVICERADAR_TEST_DATABASE_URL_FILE`, `SRQL_TEST_DATABASE_URL`, `SRQL_TEST_DATABASE_URL_FILE` |
| `DATABASE_INTERVAL_MS_QUEUE` | `CONTROL_DATABASE_QUEUE_INTERVAL_MS`, `DATABASE_QUEUE_INTERVAL_MS`, `SERVICERADAR_TEST_DATABASE_QUEUE_INTERVAL_MS`, `SRQL_TEST_DATABASE_QUEUE_INTERVAL_MS` |
| `DATABASE_MS_QUEUE_TARGET` | `CONTROL_DATABASE_QUEUE_TARGET_MS`, `DATABASE_QUEUE_TARGET_MS`, `SERVICERADAR_TEST_DATABASE_QUEUE_TARGET_MS`, `SRQL_TEST_DATABASE_QUEUE_TARGET_MS` |
| `CNPG_PASSWORD` | `CNPG_PASSWORD`, `CNPG_PASSWORD_FILE`, `TEST_CNPG_PASSWORD` |
| `CNPG_USERNAME` | `CNPG_USERNAME`, `CNPG_USERNAME_FILE`, `TEST_CNPG_USERNAME` |
| `ALERTS_OBAN_QUEUE` | `OBAN_QUEUE_ALERTS`, `WEB_NG_OBAN_QUEUE_ALERTS` |
| `CHECKS_OBAN_QUEUE_SERVICE` | `OBAN_QUEUE_SERVICE_CHECKS`, `WEB_NG_OBAN_QUEUE_SERVICE_CHECKS` |
| `CLUSTER_DNS_QUERY` | `CLUSTER_DNS_QUERY`, `DNS_CLUSTER_QUERY` |
| `CNPG_DATABASE` | `CNPG_DATABASE`, `TEST_CNPG_DATABASE` |
| `CNPG_HOST` | `CNPG_HOST`, `TEST_CNPG_HOST` |
| `CNPG_INTERVAL_MS_QUEUE` | `CNPG_QUEUE_INTERVAL_MS`, `TEST_CNPG_QUEUE_INTERVAL_MS` |
| `CNPG_MS_QUEUE_TARGET` | `CNPG_QUEUE_TARGET_MS`, `TEST_CNPG_QUEUE_TARGET_MS` |
| `CNPG_POOL_SIZE` | `CNPG_POOL_SIZE`, `TEST_CNPG_POOL_SIZE` |
| `CNPG_PORT` | `CNPG_PORT`, `TEST_CNPG_PORT` |
| `DATABASE_MS_POOL_TIMEOUT` | `CONTROL_DATABASE_POOL_TIMEOUT_MS`, `DATABASE_POOL_TIMEOUT_MS` |
| `DATABASE_MS_TIMEOUT` | `CONTROL_DATABASE_TIMEOUT_MS`, `DATABASE_TIMEOUT_MS` |
| `EDGE_OBAN_QUEUE` | `OBAN_QUEUE_EDGE`, `WEB_NG_OBAN_QUEUE_EDGE` |
| `ENABLED_OBAN` | `SERVICERADAR_CORE_OBAN_ENABLED`, `SERVICERADAR_WEB_NG_OBAN_ENABLED` |
| `ENABLED_REPO` | `CONTROL_REPO_ENABLED`, `SERVICERADAR_CORE_REPO_ENABLED` |
| `EVENTS_OBAN_QUEUE` | `OBAN_QUEUE_EVENTS`, `WEB_NG_OBAN_QUEUE_EVENTS` |
| `INTEGRATIONS_OBAN_QUEUE` | `OBAN_QUEUE_INTEGRATIONS`, `WEB_NG_OBAN_QUEUE_INTEGRATIONS` |
| `NOTIFICATIONS_OBAN_QUEUE` | `OBAN_QUEUE_NOTIFICATIONS`, `WEB_NG_OBAN_QUEUE_NOTIFICATIONS` |
| `NOTIFIER_OBAN` | `OBAN_NOTIFIER`, `WEB_NG_OBAN_NOTIFIER` |
| `OBAN_ONBOARDING_QUEUE` | `OBAN_QUEUE_ONBOARDING`, `WEB_NG_OBAN_QUEUE_ONBOARDING` |
| `OBAN_QUEUE_SWEEPS` | `OBAN_QUEUE_SWEEPS`, `WEB_NG_OBAN_QUEUE_SWEEPS` |

**Effect of 4.1 alone: 676 names collapse to 622 distinct values.**
54 of the names in this codebase are spellings of a value that
already has another spelling.

## 5. Partitioning: why this cannot be one config manager

A single `EnvironmentConfig` embedded into a single manager is a global rebuild
trigger. Today `ServiceradarConfig.Rules` reads `priv/ruleset.binpb` at COMPILE
time (`config/manager_config/elixir/BUILD.bazel`), Rust does `include_bytes!`, Go
does `go:embed`. That is the right design for hermeticity and the wrong granularity
for a graph: with all 676 values in one message, changing a log retention default
invalidates every target that embeds it -- which, once phase 7 lands, is every
Elixir application, every Rust crate that reads config, and everything downstream.

The measurement says the partitioning is natural, not forced:

| consumer file reads N partitions | files |
|---|---|
| 1 | 88 |
| 2 | 10 |
| 3 | 4 |
| 5 | 1 |
| 6 | 1 |
| 7 | 1 |
| 12 | 1 |
| 13 | 1 |
| 14 | 1 |

**88 of the 108 consumer files read exactly one partition.** Only 6
read more than three, and four of those are `config/runtime.exs`:

| file | partitions read |
|---|---|
| [elixir/web-ng/config/runtime.exs](elixir/web-ng/config/runtime.exs) | 14 |
| [elixir/serviceradar_core/config/runtime.exs](elixir/serviceradar_core/config/runtime.exs) | 13 |
| [elixir/serviceradar_core_elx/config/runtime.exs](elixir/serviceradar_core_elx/config/runtime.exs) | 12 |
| [elixir/serviceradar_core/lib/serviceradar/cluster/coordinator_children.ex](elixir/serviceradar_core/lib/serviceradar/cluster/coordinator_children.ex) | 7 |
| [elixir/serviceradar_agent_gateway/config/runtime.exs](elixir/serviceradar_agent_gateway/config/runtime.exs) | 6 |
| [elixir/serviceradar_core_elx/test/serviceradar_core_elx/production_runtime_config_test.exs](elixir/serviceradar_core_elx/test/serviceradar_core_elx/production_runtime_config_test.exs) | 5 |

So the hub problem is confined to the four `runtime.exs` files, and those are
evaluated at BOOT, not compiled into modules. Keep their dependency on the config
artifacts a runtime `data` dependency and the release does not recompile when a
partition changes; keep the per-module reads inside the module that needs them and
each module depends on exactly one partition. The failure mode to avoid is the
tempting one: resolving everything in `runtime.exs` and passing it down through
`Application.get_env`, which reintroduces the single hub in a different shape.

### 5.1 Proposed partitions

One message, one committed textproto fragment, one `binpb`, one target per language
per partition. `config/environments/<env>/<partition>.textproto` composes into the
environment; a consumer depends on `//config/manager_config/<lang>:<partition>`.

| partition | names | secrets | read sites | consumer files | Helm-set | covers |
|---|---|---|---|---|---|---|
| `database` | 90 | 19 | 212 | 23 | 41 | CNPG coordinates, pool and TLS posture, plus every test-database spelling |
| `observability` | 71 | 1 | 124 | 19 | 26 | OTel export, log/metric retention, chunk intervals, GeoIP databases |
| `edge` | 95 | 10 | 118 | 22 | 53 | agents, gateways, onboarding packages, remote access, releases |
| `messaging` | 52 | 1 | 90 | 13 | 16 | NATS, JetStream consumers, event writer, sync ingestion |
| `integrations` | 56 | 8 | 76 | 15 | 24 | Armis, OTX, AWX/Ansible, Proxmox, GitHub, advisory feeds |
| `identity` | 40 | 3 | 76 | 8 | 27 | SPIFFE, mTLS posture, core/datasvc endpoints and trust domain |
| `cluster` | 24 | 1 | 66 | 9 | 16 | libcluster topology, distribution, node identity |
| `web` | 56 | 8 | 60 | 9 | 29 | Phoenix endpoint, sessions, auth, admin surfaces, god view |
| `jobs` | 34 | 0 | 54 | 5 | 16 | Oban queues, notifier, cron schedules |
| `analysis` | 38 | 0 | 53 | 13 | 17 | anomaly, MTR, topology, prefix tags, enrichment |
| `plugins` | 36 | 4 | 47 | 6 | 24 | plugin storage, signing, first-party bundle, native add-ons |
| `cold_tier` | 38 | 4 | 43 | 4 | 7 | cold storage tiering, S3, FDW |
| `testing` | 15 | 0 | 19 | 11 | 5 | fixture selection, shard/partition, benchmark sizing |
| `mail` | 14 | 1 | 17 | 6 | 14 | SMTP relay, Mailgun, notification delivery |
| `secrets_infra` | 4 | 4 | 10 | 4 | 3 | Cloak/OpenBao provider wiring |
| `platform` | 6 | 0 | 9 | 7 | 2 | toolchain and OS -- NOT ServiceRadar configuration |
| `control_plane` | 6 | 3 | 6 | 1 | 2 | hosted control-plane JWT and runtime token |
| `srql` | 1 | 0 | 2 | 2 | 0 | SRQL service knobs |

`platform` is not a partition and gets no manager: `HOME`, `MIX_ENV`, `CI`, the
Bazel runfiles variables and the Rustler temp dir are toolchain facts the process
is entitled to read. They stay as environment reads and the exit criterion excludes
them explicitly, by name, rather than by pattern.

### 5.2 What this buys, concretely

| change | rebuilds with one manager | rebuilds with partitions |
|---|---|---|
| a `cold_tier` value | all 108 consumer files | 4 |
| a `mail` value | all 108 consumer files | 6 |
| a `jobs` value | all 108 consumer files | 5 |
| a `plugins` value | all 108 consumer files | 6 |
| a `testing` value | all 108 consumer files | 11 |

### 5.3 Ordering constraint

Partitions are disjoint by name, but not independent in review: `database`,
`identity` and `messaging` are the three the fixture lifecycle already depends on,
and they are the three that phases 1-6 built the Rust and Go managers around. They
go first because they are the only partitions with a working end-to-end path today.

## 6. Full inventory and substitution plan

Every distinct name, its destination, and how it is set today. This is the whole
surface -- nothing is elided.

Column meanings:

- **alias of** -- the canonical name of the group from section 4.1. A row with an
  alias contributes no field of its own; it is deleted and its call site rewritten
  to the canonical destination.
- **destination** -- `partition.field` for configuration, `secret: partition.name`
  for anything SecretManager resolves. A destination that already exists in
  `config/proto/config.proto` is shown as the bare field path (for example
  `database.host`); everything else is proposed by this document.
- **set by** -- where the value actually comes from today; `-` means nothing in this
  repository sets it.
- **R/W** -- read sites / write sites (`put_env`, `delete_env`, test `with_env`).


### 6.1 `database` -- 90 names, 19 secrets, 212 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `AGE_GRAPH_NAME` | 2/0 | config |  | `database.age_graph_name` | - |
| `CNPG_ADMIN_DATABASE` | 1/0 | config |  | `database.admin_database` | scripts |
| `CNPG_ADMIN_PASSWORD` | 1/0 | secret |  | secret: `database.owning_role_password` | helm |
| `CNPG_ADMIN_PASSWORD_FILE` | 1/0 | secret | `CNPG_ADMIN_PASSWORD` | secret: `database.owning_role_password` | - |
| `CNPG_ADMIN_USERNAME` | 1/0 | config |  | database.owning_role | helm |
| `CNPG_ADMIN_USERNAME_FILE` | 1/0 | config | `CNPG_ADMIN_USERNAME` | database.owning_role | - |
| `CNPG_APP_PASSWORD` | 2/0 | secret | `CNPG_PASSWORD` | secret: `database.password` | helm,scripts |
| `CNPG_APP_PASSWORD_FILE` | 2/0 | secret | `CNPG_PASSWORD` | secret: `database.password` | - |
| `CNPG_APP_USER` | 1/0 | config | `CNPG_USERNAME` | database.connecting_role | helm,scripts |
| `CNPG_CA_FILE` | 4/0 | material |  | secret: `database.ca_cert` | ci-legacy,helm,scripts |
| `CNPG_CERT_DIR` | 7/0 | material |  | (deleted -- the three PEMs are resolved by name, not located by directory) | scripts |
| `CNPG_CERT_FILE` | 4/0 | material |  | secret: `database.client_cert` | helm,scripts |
| `CNPG_DATABASE` | 5/0 | config |  | database.database | docker,helm,scripts |
| `CNPG_HOST` | 6/0 | config |  | database.host | docker,helm,scripts |
| `CNPG_KEY_FILE` | 4/0 | secret |  | secret: `database.client_key` | helm,scripts |
| `CNPG_PASSWORD` | 12/0 | secret |  | secret: `database.password` | docker,helm,scripts |
| `CNPG_PASSWORD_FILE` | 5/0 | secret | `CNPG_PASSWORD` | secret: `database.password` | - |
| `CNPG_POOL_SIZE` | 1/0 | config |  | database.pool_size | - |
| `CNPG_PORT` | 5/0 | config |  | database.port | docker,helm,scripts |
| `CNPG_QUEUE_INTERVAL_MS` | 1/0 | config |  | database.queue_interval_ms | - |
| `CNPG_QUEUE_TARGET_MS` | 1/0 | config |  | database.queue_target_ms | - |
| `CNPG_SEARCH_PATH` | 8/0 | config |  | database.search_path | - |
| `CNPG_SSL_MODE` | 9/0 | config |  | database.tls_mode | docker,helm,scripts |
| `CNPG_TLS_SERVER_NAME` | 8/0 | config |  | database.tls_server_name | helm,scripts |
| `CNPG_USERNAME` | 7/0 | config |  | database.connecting_role | docker,helm,scripts |
| `CNPG_USERNAME_FILE` | 1/0 | config | `CNPG_USERNAME` | database.connecting_role | - |
| `CONTROL_DATABASE_POOL_TIMEOUT_MS` | 2/0 | config |  | `control_database.pool_timeout_ms` | helm |
| `CONTROL_DATABASE_QUEUE_INTERVAL_MS` | 2/0 | config |  | `control_database.queue_interval_ms` | helm |
| `CONTROL_DATABASE_QUEUE_TARGET_MS` | 2/0 | config |  | `control_database.queue_target_ms` | helm |
| `CONTROL_DATABASE_TIMEOUT_MS` | 2/0 | config |  | `control_database.timeout_ms` | helm |
| `CONTROL_REPO_ENABLED` | 2/0 | config |  | `control_database.enabled` | helm |
| `CONTROL_REPO_POOL_SIZE` | 2/0 | config |  | `control_database.pool_size` | helm |
| `DATABASE_POOL_TIMEOUT_MS` | 3/0 | config |  | `database.pool_timeout_ms` | helm |
| `DATABASE_PREPARE` | 3/0 | config |  | `database.prepare` | helm |
| `DATABASE_QUEUE_INTERVAL_MS` | 3/0 | config |  | database.queue_interval_ms | helm |
| `DATABASE_QUEUE_TARGET_MS` | 3/0 | config |  | database.queue_target_ms | helm |
| `DATABASE_TIMEOUT_MS` | 3/0 | config |  | `database.timeout_ms` | helm |
| `DATABASE_URL` | 4/0 | config |  | database (assembled DSN) | - |
| `ECTO_IPV6` | 3/0 | config |  | `database.ecto_ipv6` | - |
| `PGSSLROOTCERT` | 1/0 | config | `CNPG_CA_FILE` | secret: `database.ca_cert` | ci-legacy,helm,scripts |
| `POOL_SIZE` | 3/0 | config |  | `database.pool_size` | helm |
| `SERVICERADAR_AGE_GRAPH_NAME` | 2/0 | config | `AGE_GRAPH_NAME` | `database.age_graph_name` | - |
| `SERVICERADAR_CNPG_STORAGE_SIZE` | 1/0 | config |  | `database.cnpg_storage_size` | helm |
| `SERVICERADAR_COORDINATOR_DB_HOST` | 1/0 | config |  | `database.coordinator_db_host` | helm |
| `SERVICERADAR_DB_BOOTSTRAP_ATTEMPTS` | 1/0 | config |  | `database.bootstrap_attempts` | - |
| `SERVICERADAR_DB_BOOTSTRAP_DELAY_MS` | 1/0 | config |  | `database.bootstrap_delay_ms` | - |
| `SERVICERADAR_MIGRATIONS_GATE` | 5/10 | config |  | `database.migrations_gate` | - |
| `SERVICERADAR_MIGRATIONS_MARKER_PATH` | 3/4 | config |  | `database.migrations_marker_path` | - |
| `SERVICERADAR_MIGRATION_CONCURRENT_INDEXES` | 1/0 | config |  | `database.migration_concurrent_indexes` | - |
| `SERVICERADAR_MIGRATION_ONLY` | 3/0 | config |  | `database.migration_only` | helm |
| `SERVICERADAR_TEST_ADMIN_URL` | 1/0 | config | `SRQL_TEST_ADMIN_URL` | database (assembled DSN) | scripts |
| `SERVICERADAR_TEST_DATABASE_CA_CERT` | 2/0 | material | `CNPG_CA_FILE` | secret: `database.ca_cert` | - |
| `SERVICERADAR_TEST_DATABASE_CA_CERT_FILE` | 2/0 | material | `CNPG_CA_FILE` | secret: `database.ca_cert` | ci-legacy,scripts |
| `SERVICERADAR_TEST_DATABASE_CERT` | 2/0 | material | `CNPG_CERT_FILE` | secret: `database.client_cert` | - |
| `SERVICERADAR_TEST_DATABASE_KEY` | 2/0 | secret | `CNPG_KEY_FILE` | secret: `database.client_key` | - |
| `SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS` | 1/0 | config | `SRQL_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS` | database.ownership_timeout_ms | scripts |
| `SERVICERADAR_TEST_DATABASE_POOL_SIZE` | 1/0 | config | `SRQL_TEST_DATABASE_POOL_SIZE` | database.pool_size | scripts |
| `SERVICERADAR_TEST_DATABASE_QUEUE_INTERVAL_MS` | 1/0 | config | `SRQL_TEST_DATABASE_QUEUE_INTERVAL_MS` | database.queue_interval_ms | scripts |
| `SERVICERADAR_TEST_DATABASE_QUEUE_TARGET_MS` | 1/0 | config | `SRQL_TEST_DATABASE_QUEUE_TARGET_MS` | database.queue_target_ms | scripts |
| `SERVICERADAR_TEST_DATABASE_SERVER_NAME` | 2/0 | config | `CNPG_TLS_SERVER_NAME` | database.tls_server_name | - |
| `SERVICERADAR_TEST_DATABASE_SSL` | 1/0 | config | `SRQL_TEST_DATABASE_SSL` | database.tls_mode | - |
| `SERVICERADAR_TEST_DATABASE_SSLMODE` | 2/0 | config | `CNPG_SSL_MODE` | database.tls_mode | - |
| `SERVICERADAR_TEST_DATABASE_SSL_VERIFY` | 1/0 | config | `SRQL_TEST_DATABASE_SSL_VERIFY` | database.tls_mode | - |
| `SERVICERADAR_TEST_DATABASE_URL` | 2/2 | config | `SRQL_TEST_DATABASE_URL` | database (assembled DSN) | scripts |
| `SERVICERADAR_TEST_DATABASE_URL_FILE` | 1/0 | config | `SRQL_TEST_DATABASE_URL` | database (assembled DSN) | - |
| `SRQL_TEST_ADMIN_URL` | 1/0 | config |  | database (assembled DSN) | - |
| `SRQL_TEST_DATABASE_CA_CERT` | 2/0 | material | `CNPG_CA_FILE` | secret: `database.ca_cert` | ci-legacy,scripts |
| `SRQL_TEST_DATABASE_CA_CERT_FILE` | 2/0 | material | `CNPG_CA_FILE` | secret: `database.ca_cert` | scripts |
| `SRQL_TEST_DATABASE_CERT` | 2/0 | material | `CNPG_CERT_FILE` | secret: `database.client_cert` | - |
| `SRQL_TEST_DATABASE_KEY` | 2/0 | secret | `CNPG_KEY_FILE` | secret: `database.client_key` | - |
| `SRQL_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS` | 1/0 | config |  | database.ownership_timeout_ms | - |
| `SRQL_TEST_DATABASE_POOL_SIZE` | 1/0 | config |  | database.pool_size | - |
| `SRQL_TEST_DATABASE_QUEUE_INTERVAL_MS` | 1/0 | config |  | database.queue_interval_ms | - |
| `SRQL_TEST_DATABASE_QUEUE_TARGET_MS` | 1/0 | config |  | database.queue_target_ms | - |
| `SRQL_TEST_DATABASE_SERVER_NAME` | 2/0 | config | `CNPG_TLS_SERVER_NAME` | database.tls_server_name | - |
| `SRQL_TEST_DATABASE_SSL` | 1/0 | config |  | database.tls_mode | - |
| `SRQL_TEST_DATABASE_SSLMODE` | 2/0 | config | `CNPG_SSL_MODE` | database.tls_mode | - |
| `SRQL_TEST_DATABASE_SSL_VERIFY` | 1/0 | config |  | database.tls_mode | - |
| `SRQL_TEST_DATABASE_URL` | 3/0 | config |  | database (assembled DSN) | - |
| `SRQL_TEST_DATABASE_URL_FILE` | 1/0 | config | `SRQL_TEST_DATABASE_URL` | database (assembled DSN) | - |
| `STATE_CHANGE_EVENTS_ENABLED` | 2/4 | config |  | `database.state_change_events_enabled` | - |
| `STATE_MONITOR_ENABLED` | 1/0 | config |  | `database.state_monitor_enabled` | - |
| `TEST_CNPG_DATABASE` | 1/0 | config |  | database.database | - |
| `TEST_CNPG_HOST` | 1/0 | config |  | database.host | - |
| `TEST_CNPG_PASSWORD` | 1/0 | secret |  | secret: `database.password` | - |
| `TEST_CNPG_POOL_SIZE` | 1/0 | config |  | database.pool_size | - |
| `TEST_CNPG_PORT` | 1/0 | config |  | database.port | - |
| `TEST_CNPG_QUEUE_INTERVAL_MS` | 1/0 | config |  | database.queue_interval_ms | - |
| `TEST_CNPG_QUEUE_TARGET_MS` | 1/0 | config |  | database.queue_target_ms | - |
| `TEST_CNPG_USERNAME` | 1/0 | config |  | database.connecting_role | - |

### 6.2 `observability` -- 71 names, 1 secrets, 124 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `GEOLITE_CITY_ENABLED` | 3/0 | config |  | `observability.geolite_city_enabled` | helm |
| `GEOLITE_MMDB_DIR` | 9/0 | config |  | `observability.geolite_mmdb_dir` | helm |
| `GEOLITE_MMDB_DOWNLOAD_ENABLED` | 1/0 | config |  | `observability.geolite_mmdb_download_enabled` | helm |
| `GEOLITE_MMDB_SCHEDULER_ENABLED` | 1/0 | config | `GEOLITE_MMDB_DOWNLOAD_ENABLED` | `observability.geolite_mmdb_download_enabled` | helm |
| `HEALTH_CHECK_REGISTRAR_ENABLED` | 1/0 | config |  | `observability.health_check_registrar_enabled` | helm |
| `HEALTH_CHECK_RUNNER_ENABLED` | 1/0 | config |  | `observability.health_check_runner_enabled` | helm |
| `IPINFO_MMDB_SCHEDULER_ENABLED` | 1/0 | config |  | `observability.ipinfo_mmdb_scheduler_enabled` | helm |
| `LOG_PROMOTION_CONSUMER_DELIVER_POLICY` | 1/0 | config |  | `observability.log_promotion_consumer_deliver_policy` | - |
| `LOG_PROMOTION_CONSUMER_DOMAIN` | 1/0 | config |  | `observability.log_promotion_consumer_domain` | - |
| `LOG_PROMOTION_CONSUMER_ENABLED` | 2/0 | config |  | `observability.log_promotion_consumer_enabled` | helm |
| `LOG_PROMOTION_CONSUMER_FILTER` | 1/0 | config |  | `observability.log_promotion_consumer_filter` | - |
| `LOG_PROMOTION_CONSUMER_NAME` | 1/0 | config |  | `observability.log_promotion_consumer_name` | - |
| `LOG_PROMOTION_CONSUMER_RETRY_COUNT` | 1/0 | config |  | `observability.log_promotion_consumer_retry_count` | - |
| `LOG_PROMOTION_CONSUMER_RETRY_TIMEOUT_MS` | 1/0 | config |  | `observability.log_promotion_consumer_retry_timeout_ms` | - |
| `LOG_PROMOTION_CONSUMER_STREAM` | 1/0 | config |  | `observability.log_promotion_consumer_stream` | - |
| `METRIC_FIXTURE_PROFILE_DIR` | 2/0 | config |  | `observability.metric_fixture_profile_dir` | - |
| `METRIC_FIXTURE_PROFILE_REPEAT` | 1/0 | config |  | `observability.metric_fixture_profile_repeat` | - |
| `METRIC_INSERT_LOG_LEVEL` | 1/0 | config |  | `observability.metric_insert_log_level` | - |
| `METRIC_INSERT_PARALLELISM` | 1/0 | config |  | `observability.metric_insert_parallelism` | - |
| `METRIC_INSERT_ROLLBACK` | 1/0 | config |  | `observability.metric_insert_rollback` | - |
| `METRIC_INSERT_RUN_ID` | 1/0 | config |  | `observability.metric_insert_run_id` | - |
| `METRIC_INSERT_STRATEGY` | 1/0 | config |  | `observability.metric_insert_strategy` | - |
| `OTEL_CERT_DIR` | 1/0 | material |  | secret: `observability.cert_dir` | helm |
| `OTEL_CERT_NAME` | 1/0 | config |  | `observability.cert_name` | helm |
| `OTEL_ENABLED` | 1/0 | config |  | `observability.enabled` | - |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | 4/0 | config |  | `observability.exporter_otlp_endpoint` | helm |
| `OTEL_EXPORTER_OTLP_RETRY_BASE_DELAY_MS` | 4/0 | config |  | `observability.exporter_otlp_retry_base_delay_ms` | - |
| `OTEL_EXPORTER_OTLP_RETRY_MAX_ATTEMPTS` | 4/0 | config |  | `observability.exporter_otlp_retry_max_attempts` | - |
| `OTEL_EXPORTER_OTLP_RETRY_MAX_DELAY_MS` | 4/0 | config |  | `observability.exporter_otlp_retry_max_delay_ms` | - |
| `OTEL_EXPORTER_OTLP_TIMEOUT_MS` | 4/0 | config |  | `observability.exporter_otlp_timeout_ms` | - |
| `OTEL_TRACES_SAMPLER_ARG` | 1/0 | config |  | `observability.traces_sampler_arg` | helm |
| `SERVICERADAR_DATASET_SNAPSHOT_KEEP_LAST` | 2/0 | config |  | `observability.dataset_snapshot_keep_last` | helm |
| `SERVICERADAR_DATASET_SNAPSHOT_RETENTION_DAYS` | 2/0 | config |  | `observability.dataset_snapshot_retention_days` | helm |
| `SERVICERADAR_FLOW_ATTRIBUTION_RETENTION_MINUTES` | 2/0 | config |  | `observability.flow_attribution_retention_minutes` | helm |
| `SERVICERADAR_INTERNAL_LOG_LIVE_NATS` | 1/0 | config |  | `observability.internal_log_live_nats` | - |
| `SERVICERADAR_LOGS_CHUNK_INTERVAL_HOURS` | 5/0 | config |  | `observability.logs_chunk_interval_hours` | helm |
| `SERVICERADAR_LOGS_RETENTION_DAYS` | 3/0 | config |  | `observability.logs_retention_days` | helm |
| `SERVICERADAR_LOG_LEVEL` | 1/0 | config |  | `observability.log_level` | - |
| `SERVICERADAR_OBSERVABILITY_RETENTION_BATCH_SIZE` | 2/0 | config |  | `observability.observability_retention_batch_size` | helm |
| `SERVICERADAR_OCSF_EVENTS_CHUNK_INTERVAL_HOURS` | 3/0 | config |  | `observability.ocsf_events_chunk_interval_hours` | - |
| `SERVICERADAR_OCSF_EVENTS_RETENTION_DAYS` | 1/0 | config |  | `observability.ocsf_events_retention_days` | - |
| `SERVICERADAR_OCSF_NETWORK_ACTIVITY_CHUNK_INTERVAL_HOURS` | 2/0 | config |  | `observability.ocsf_network_activity_chunk_interval_hours` | helm |
| `SERVICERADAR_OCSF_NETWORK_ACTIVITY_RETENTION_DAYS` | 2/0 | config |  | `observability.ocsf_network_activity_retention_days` | helm |
| `SERVICERADAR_OTEL_COLLECTOR_ADDON_ARTIFACTS` | 1/0 | config |  | `observability.collector_addon_artifacts` | - |
| `SERVICERADAR_OTEL_COLLECTOR_ADDON_OCI_DIGEST` | 1/0 | config |  | `observability.collector_addon_oci_digest` | - |
| `SERVICERADAR_OTEL_COLLECTOR_ADDON_OCI_REF` | 1/0 | config |  | `observability.collector_addon_oci_ref` | - |
| `SERVICERADAR_OTEL_COLLECTOR_ADDON_VERSION` | 1/0 | config |  | `observability.collector_addon_version` | - |
| `SERVICERADAR_OTEL_METRICS_CHUNK_INTERVAL_HOURS` | 1/0 | config |  | `observability.metrics_chunk_interval_hours` | - |
| `SERVICERADAR_OTEL_METRICS_RETENTION_DAYS` | 2/0 | config |  | `observability.metrics_retention_days` | - |
| `SERVICERADAR_OTEL_METRIC_POINTS_CHUNK_INTERVAL_HOURS` | 1/0 | config |  | `observability.metric_points_chunk_interval_hours` | - |
| `SERVICERADAR_OTEL_METRIC_POINTS_RETENTION_DAYS` | 1/0 | config |  | `observability.metric_points_retention_days` | - |
| `SERVICERADAR_OTEL_TRACES_CHUNK_INTERVAL_HOURS` | 3/0 | config |  | `observability.traces_chunk_interval_hours` | helm |
| `SERVICERADAR_OTEL_TRACES_RETENTION_DAYS` | 3/0 | config |  | `observability.traces_retention_days` | helm |
| `SERVICERADAR_OTLP_GRPC_ENDPOINT` | 1/0 | config |  | `observability.otlp_grpc_endpoint` | - |
| `SERVICERADAR_OTLP_GRPC_REQUIRES_PRIVATE_CA` | 1/0 | config |  | `observability.otlp_grpc_requires_private_ca` | - |
| `SERVICERADAR_OTLP_HTTP_ENDPOINT` | 1/0 | config |  | `observability.otlp_http_endpoint` | - |
| `SERVICERADAR_ROOT_SPAN_RATIO_MIN_SPANS` | 1/0 | config |  | `observability.root_span_ratio_min_spans` | - |
| `SERVICERADAR_ROOT_SPAN_RATIO_THRESHOLD` | 1/0 | config |  | `observability.root_span_ratio_threshold` | - |
| `SERVICERADAR_SWEEP_EXECUTION_RETENTION_DAYS` | 2/0 | config |  | `observability.sweep_execution_retention_days` | helm |
| `SERVICERADAR_SWEEP_HOST_RESULT_RETENTION_DAYS` | 2/0 | config |  | `observability.sweep_host_result_retention_days` | helm |
| `SERVICERADAR_TIMESERIES_METRICS_RETENTION_DAYS` | 1/0 | config |  | `observability.timeseries_metrics_retention_days` | - |
| `SERVICERADAR_TRACE_SUMMARY_RETENTION_DAYS` | 2/0 | config |  | `observability.trace_summary_retention_days` | helm |
| `SERVICERADAR_TRIVY_RETENTION_DAYS` | 2/0 | config |  | `observability.trivy_retention_days` | helm |
| `TRACE_SUMMARIES_CLEANUP_BATCH_SIZE` | 1/0 | config |  | `observability.trace_summaries_cleanup_batch_size` | - |
| `TRACE_SUMMARIES_CLEANUP_TIMEOUT_MS` | 1/0 | config |  | `observability.trace_summaries_cleanup_timeout_ms` | - |
| `TRACE_SUMMARIES_CLEANUP_TIME_BUDGET_MS` | 1/0 | config |  | `observability.trace_summaries_cleanup_time_budget_ms` | - |
| `TRACE_SUMMARIES_PROBE_TIMEOUT_MS` | 1/0 | config |  | `observability.trace_summaries_probe_timeout_ms` | - |
| `TRACE_SUMMARIES_REFRESH_CRON` | 4/0 | config |  | `observability.trace_summaries_refresh_cron` | - |
| `TRACE_SUMMARIES_REMAINING_ESTIMATE_TIMEOUT_MS` | 1/0 | config |  | `observability.trace_summaries_remaining_estimate_timeout_ms` | - |
| `TRACE_SUMMARIES_UPSERT_TIMEOUT_MS` | 1/0 | config |  | `observability.trace_summaries_upsert_timeout_ms` | - |
| `TRACE_SUMMARIES_WATERMARK_TIMEOUT_MS` | 1/0 | config |  | `observability.trace_summaries_watermark_timeout_ms` | - |

### 6.3 `edge` -- 95 names, 10 secrets, 118 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `AGENT_COMMAND_CLEANUP_INTERVAL_SECONDS` | 1/0 | config |  | `edge.command_cleanup_interval_seconds` | - |
| `AGENT_COMMAND_RETENTION_DAYS` | 1/0 | config |  | `edge.command_retention_days` | - |
| `AGENT_GATEWAY_ICMP_METRICS_ENABLED` | 1/0 | config |  | `edge.icmp_metrics_enabled` | - |
| `AGENT_GATEWAY_ICMP_METRICS_SHADOW_ENABLED` | 1/0 | config | `AGENT_GATEWAY_ICMP_METRICS_ENABLED` | `edge.icmp_metrics_enabled` | - |
| `AGENT_GATEWAY_ICMP_METRICS_SUBJECT_PREFIX` | 1/0 | config |  | `edge.icmp_metrics_subject_prefix` | - |
| `AGENT_GATEWAY_MTR_METRICS_ENABLED` | 1/0 | config |  | `edge.mtr_metrics_enabled` | - |
| `AGENT_GATEWAY_MTR_METRICS_SUBJECT_PREFIX` | 1/0 | config |  | `edge.mtr_metrics_subject_prefix` | - |
| `AGENT_GATEWAY_NATS_CERT_NAME` | 1/0 | config |  | `edge.nats_cert_name` | - |
| `AGENT_GATEWAY_NATS_CREDS_FILE` | 1/0 | config |  | `edge.nats_creds_file` | helm |
| `AGENT_GATEWAY_NATS_SERVER_NAME` | 1/0 | config |  | `edge.nats_server_name` | helm |
| `AGENT_GATEWAY_NATS_TLS` | 1/0 | config |  | `edge.nats_tls` | helm |
| `AGENT_GATEWAY_NATS_URL` | 1/0 | config | `NATS_URL` | nats.url | helm |
| `AGENT_GATEWAY_NATS_USER` | 1/0 | config |  | `edge.nats_user` | - |
| `AGENT_GATEWAY_OTLP_RELAY_DERIVED_METRICS_SUBJECT` | 1/0 | config |  | `edge.otlp_relay_derived_metrics_subject` | helm |
| `AGENT_GATEWAY_OTLP_RELAY_LOGS_SUBJECT` | 1/0 | config |  | `edge.otlp_relay_logs_subject` | helm |
| `AGENT_GATEWAY_OTLP_RELAY_METRICS_SUBJECT` | 1/0 | config |  | `edge.otlp_relay_metrics_subject` | helm |
| `AGENT_GATEWAY_OTLP_RELAY_PUBLISH_ENABLED` | 1/0 | config |  | `edge.otlp_relay_publish_enabled` | helm |
| `AGENT_GATEWAY_OTLP_RELAY_TRACES_SUBJECT` | 1/0 | config |  | `edge.otlp_relay_traces_subject` | helm |
| `AGENT_GATEWAY_PLUGIN_METRICS_ENABLED` | 1/0 | config |  | `edge.plugin_metrics_enabled` | helm |
| `AGENT_GATEWAY_PLUGIN_METRICS_SUBJECT_PREFIX` | 1/0 | config |  | `edge.plugin_metrics_subject_prefix` | helm |
| `AGENT_GATEWAY_RPERF_METRICS_ENABLED` | 1/0 | config |  | `edge.rperf_metrics_enabled` | - |
| `AGENT_GATEWAY_RPERF_METRICS_SUBJECT_PREFIX` | 1/0 | config |  | `edge.rperf_metrics_subject_prefix` | - |
| `AGENT_GATEWAY_SNMP_INTERFACE_METRICS` | 1/0 | config |  | `edge.snmp_interface_metrics` | helm |
| `AGENT_GATEWAY_SNMP_METRICS_ENABLED` | 1/0 | config |  | `edge.snmp_metrics_enabled` | helm |
| `AGENT_GATEWAY_SNMP_METRICS_SUBJECT_PREFIX` | 1/0 | config |  | `edge.snmp_metrics_subject_prefix` | helm |
| `AGENT_GATEWAY_SWEEP_METRICS_ENABLED` | 1/0 | config |  | `edge.sweep_metrics_enabled` | - |
| `AGENT_GATEWAY_SWEEP_METRICS_SUBJECT_PREFIX` | 1/0 | config |  | `edge.sweep_metrics_subject_prefix` | - |
| `AGENT_GATEWAY_SYSMON_METRICS_ENABLED` | 1/0 | config |  | `edge.sysmon_metrics_enabled` | helm |
| `AGENT_GATEWAY_SYSMON_METRICS_SUBJECT_PREFIX` | 1/0 | config |  | `edge.sysmon_metrics_subject_prefix` | helm |
| `AGENT_PLUGIN_STORAGE_PUBLIC_URL` | 1/0 | config |  | `edge.plugin_storage_public_url` | helm |
| `CAMERA_RELAY_BROWSER_STREAM_TIMEOUT_MS` | 1/0 | config |  | `edge.camera_relay_browser_stream_timeout_ms` | - |
| `CAMERA_RELAY_MAX_SESSIONS_PER_AGENT` | 1/0 | config |  | `edge.camera_relay_max_sessions_per_agent` | - |
| `CAMERA_RELAY_MAX_SESSIONS_PER_GATEWAY` | 1/0 | config |  | `edge.camera_relay_max_sessions_per_gateway` | - |
| `CAMERA_RELAY_SWEEP_INTERVAL_MS` | 1/0 | config |  | `edge.camera_relay_sweep_interval_ms` | - |
| `EDGE_ONBOARDING_ENCRYPTION_KEY` | 4/0 | secret | `SERVICERADAR_EDGE_CRYPTO_SECRET` | secret: `edge.crypto_secret` | helm |
| `GATEWAY_ARTIFACT_PATH` | 1/0 | config |  | `edge.artifact_path` | - |
| `GATEWAY_ARTIFACT_PORT` | 2/0 | config |  | `edge.artifact_port` | helm |
| `GATEWAY_CAPABILITIES` | 1/0 | config |  | `edge.capabilities` | helm |
| `GATEWAY_CA_CERT_FILE` | 1/0 | material |  | secret: `edge.ca_cert_file` | helm |
| `GATEWAY_CA_KEY_FILE` | 1/0 | secret |  | secret: `edge.ca_key_file` | helm |
| `GATEWAY_CERT_DIR` | 2/0 | material |  | secret: `edge.cert_dir` | helm |
| `GATEWAY_DOMAIN` | 1/0 | config |  | `edge.domain` | helm |
| `GATEWAY_GRPC_IDLE_TIMEOUT_MS` | 0/1 | config |  | `edge.grpc_idle_timeout_ms` | - |
| `GATEWAY_GRPC_MAX_CONCURRENT_STREAMS` | 0/1 | config |  | `edge.grpc_max_concurrent_streams` | - |
| `GATEWAY_GRPC_MAX_CONNECTIONS` | 0/1 | config |  | `edge.grpc_max_connections` | - |
| `GATEWAY_GRPC_MAX_FRAME_SIZE_BYTES` | 0/1 | config |  | `edge.grpc_max_frame_size_bytes` | - |
| `GATEWAY_GRPC_PORT` | 1/0 | config |  | `edge.grpc_port` | helm |
| `GATEWAY_ID` | 1/0 | config |  | `edge.id` | helm,scripts |
| `GATEWAY_METRICS_ENABLED` | 1/0 | config |  | `edge.metrics_enabled` | - |
| `GATEWAY_METRICS_PORT` | 1/0 | config |  | `edge.metrics_port` | helm |
| `GATEWAY_PARTITION_ID` | 1/0 | config |  | `edge.partition_id` | helm |
| `GATEWAY_RESULTS_BUFFER_FLUSH_MS` | 1/0 | config |  | `edge.results_buffer_flush_ms` | - |
| `GATEWAY_RESULTS_BUFFER_LIMIT` | 1/0 | config |  | `edge.results_buffer_limit` | - |
| `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` | 2/0 | material |  | secret: `edge.agent_release_public_key` | ci-legacy,helm |
| `SERVICERADAR_EDGE_CRYPTO_SECRET` | 5/0 | secret |  | secret: `edge.crypto_secret` | helm |
| `SERVICERADAR_ENDPOINT_INVENTORY_ADDON_ARTIFACTS` | 1/0 | config |  | `edge.endpoint_inventory_addon_artifacts` | helm |
| `SERVICERADAR_ENDPOINT_INVENTORY_ADDON_OCI_DIGEST` | 1/0 | config |  | `edge.endpoint_inventory_addon_oci_digest` | helm |
| `SERVICERADAR_ENDPOINT_INVENTORY_ADDON_OCI_REF` | 1/0 | config |  | `edge.endpoint_inventory_addon_oci_ref` | helm |
| `SERVICERADAR_ENDPOINT_INVENTORY_ADDON_VERSION` | 1/0 | config |  | `edge.endpoint_inventory_addon_version` | helm |
| `SERVICERADAR_ENDPOINT_INVENTORY_RETENTION_DAYS` | 2/0 | config |  | `edge.endpoint_inventory_retention_days` | helm |
| `SERVICERADAR_GATEWAY_ADDR` | 1/0 | config |  | `edge.gateway_addr` | helm |
| `SERVICERADAR_GATEWAY_SERVER_NAME` | 1/0 | config |  | `edge.gateway_server_name` | - |
| `SERVICERADAR_NETPROBE_ADDON_ARTIFACTS` | 1/0 | config |  | `edge.netprobe_addon_artifacts` | helm |
| `SERVICERADAR_NETPROBE_ADDON_OCI_DIGEST` | 1/0 | config |  | `edge.netprobe_addon_oci_digest` | helm |
| `SERVICERADAR_NETPROBE_ADDON_OCI_REF` | 1/0 | config |  | `edge.netprobe_addon_oci_ref` | helm |
| `SERVICERADAR_NETPROBE_ADDON_VERSION` | 1/0 | config |  | `edge.netprobe_addon_version` | helm |
| `SERVICERADAR_ONBOARDING_TOKEN_PRIVATE_KEY` | 1/0 | secret |  | secret: `edge.onboarding_token_private_key` | helm |
| `SERVICERADAR_ONBOARDING_TOKEN_PUBLIC_KEY` | 1/0 | material |  | secret: `edge.onboarding_token_public_key` | - |
| `SERVICERADAR_PLATFORM_SYNC_COMPONENT_ID` | 3/0 | config |  | `edge.platform_sync_component_id` | - |
| `SERVICERADAR_RECORDING_INTEGRITY_SECRET` | 1/0 | secret | `SERVICERADAR_EDGE_CRYPTO_SECRET` | secret: `edge.crypto_secret` | - |
| `SERVICERADAR_RELEASE_ERTS` | 3/0 | config |  | `edge.release_erts` | - |
| `SERVICERADAR_RELEASE_VERSION` | 6/5 | config |  | `edge.release_version` | helm |
| `SERVICERADAR_REMOTE_ACCESS_APP_ENABLED` | 1/0 | config |  | `edge.app_enabled` | - |
| `SERVICERADAR_REMOTE_ACCESS_BROWSER_KEY_REMEMBER_ENABLED` | 1/0 | config |  | `edge.browser_key_remember_enabled` | - |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_INGRESS_IDLE_TIMEOUT_MS` | 1/0 | config |  | `edge.desktop_ingress_idle_timeout_ms` | - |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_RDP_ENABLED` | 2/0 | config |  | `edge.desktop_rdp_enabled` | helm |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_ICE_SERVERS_JSON` | 1/0 | config |  | `edge.desktop_webrtc_ice_servers_json` | helm |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_MAX_VIEWERS_GLOBAL` | 1/0 | config |  | `edge.desktop_webrtc_max_viewers_global` | - |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_MAX_VIEWERS_PER_ACTOR` | 1/0 | config |  | `edge.desktop_webrtc_max_viewers_per_actor` | - |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_MAX_VIEWERS_PER_SESSION` | 1/0 | config |  | `edge.desktop_webrtc_max_viewers_per_session` | - |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_TURN_CREDENTIAL_TTL_SECONDS` | 1/0 | config |  | `edge.desktop_webrtc_turn_credential_ttl_seconds` | helm |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_TURN_SHARED_SECRET_FILE` | 1/0 | secret |  | secret: `edge.desktop_webrtc_turn_shared_secret_file` | helm |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID` | 2/0 | config |  | `edge.ssh_ca_key_id` | helm |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ARGS_JSON` | 2/0 | config |  | `edge.ssh_ca_signer_args_json` | helm |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ENABLED` | 2/0 | config |  | `edge.ssh_ca_signer_enabled` | helm |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_FILE` | 2/0 | config |  | `edge.ssh_certificate_policy_file` | helm |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_JSON` | 2/0 | config |  | `edge.ssh_certificate_policy_json` | - |
| `SERVICERADAR_REMOTE_ACCESS_SSH_ENABLED` | 1/0 | config |  | `edge.ssh_enabled` | helm |
| `SERVICERADAR_REMOTE_ACCESS_SSH_HOST_KEY_SKIP_VERIFY_ENABLED` | 1/0 | config |  | `edge.ssh_host_key_skip_verify_enabled` | - |
| `SERVICERADAR_REMOTE_ACCESS_TARGET_HOST_OVERRIDE_ENABLED` | 1/0 | config |  | `edge.target_host_override_enabled` | - |
| `SERVICERADAR_REMOTE_ACCESS_TARGET_PORT_OVERRIDE_ENABLED` | 1/0 | config |  | `edge.target_port_override_enabled` | - |
| `SERVICERADAR_REMOTE_ACCESS_TCP_ENABLED` | 1/0 | config |  | `edge.tcp_enabled` | - |
| `SERVICERADAR_RUNTIME_CAPABILITIES` | 1/0 | config |  | `edge.runtime_capabilities` | - |
| `SERVICE_HEARTBEAT_ENABLED` | 1/0 | config |  | `edge.service_heartbeat_enabled` | helm |
| `STATUS_HANDLER_ENABLED` | 2/0 | config |  | `edge.status_handler_enabled` | helm |

### 6.4 `messaging` -- 52 names, 1 secrets, 90 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `EVENT_BATCHER_ENABLED` | 1/0 | config |  | `messaging.event_batcher_enabled` | - |
| `EVENT_WRITER_ACK_WAIT_SECONDS` | 2/2 | config |  | `messaging.ack_wait_seconds` | - |
| `EVENT_WRITER_ANOMALY_EPISODES` | 1/7 | config |  | `messaging.anomaly_episodes` | - |
| `EVENT_WRITER_BATCH_SIZE` | 3/2 | config |  | `messaging.batch_size` | - |
| `EVENT_WRITER_BATCH_TIMEOUT` | 3/2 | config |  | `messaging.batch_timeout` | - |
| `EVENT_WRITER_BUFFER_BENCH_MAX_ACK_PENDING` | 1/0 | config |  | `messaging.buffer_bench_max_ack_pending` | - |
| `EVENT_WRITER_BUFFER_BENCH_MESSAGES` | 1/0 | config |  | `messaging.buffer_bench_messages` | - |
| `EVENT_WRITER_BUFFER_BENCH_MODE` | 1/0 | config |  | `messaging.buffer_bench_mode` | - |
| `EVENT_WRITER_BUFFER_BENCH_PAYLOAD_BYTES` | 1/0 | config |  | `messaging.buffer_bench_payload_bytes` | - |
| `EVENT_WRITER_BUFFER_BENCH_PULL_BATCH_SIZE` | 1/0 | config |  | `messaging.buffer_bench_pull_batch_size` | - |
| `EVENT_WRITER_CONSUMER_NAME` | 3/2 | config |  | `messaging.consumer_name` | - |
| `EVENT_WRITER_CONSUMER_PULL_BATCH_SIZE` | 2/2 | config |  | `messaging.consumer_pull_batch_size` | - |
| `EVENT_WRITER_ENABLED` | 4/10 | config |  | `messaging.enabled` | helm |
| `EVENT_WRITER_FLOW_CONSUMER_PULL_BATCH_SIZE` | 2/5 | config |  | `messaging.flow_consumer_pull_batch_size` | - |
| `EVENT_WRITER_FLOW_DRAIN_EVENTS` | 1/8 | config |  | `messaging.flow_drain_events` | - |
| `EVENT_WRITER_FLOW_DRAIN_EXTRA_SUBJECTS` | 1/2 | config | `EVENT_WRITER_FLOW_EXTRA_SUBJECTS` | `messaging.flow_extra_subjects` | - |
| `EVENT_WRITER_FLOW_EXTRA_SUBJECTS` | 1/10 | config |  | `messaging.flow_extra_subjects` | helm |
| `EVENT_WRITER_FLOW_MAX_ACK_PENDING` | 2/5 | config |  | `messaging.flow_max_ack_pending` | - |
| `EVENT_WRITER_FLOW_PULL_EXPIRES_NS` | 2/0 | config |  | `messaging.flow_pull_expires_ns` | - |
| `EVENT_WRITER_HOST_SLICE_SUBSCRIBER_ENABLED` | 1/0 | config |  | `messaging.host_slice_subscriber_enabled` | - |
| `EVENT_WRITER_MAX_ACK_PENDING` | 1/4 | config |  | `messaging.max_ack_pending` | - |
| `EVENT_WRITER_MAX_DELIVER` | 1/2 | config |  | `messaging.max_deliver` | - |
| `EVENT_WRITER_NATS_CREDS_FILE` | 3/0 | config |  | `messaging.nats_creds_file` | helm |
| `EVENT_WRITER_NATS_TLS` | 2/0 | config |  | `messaging.nats_tls` | helm |
| `EVENT_WRITER_NATS_URL` | 2/2 | config |  | `messaging.nats_url` | helm |
| `EVENT_WRITER_NATS_USER` | 2/0 | config |  | `messaging.nats_user` | - |
| `EVENT_WRITER_PROCESSOR_CONCURRENCY` | 1/4 | config |  | `messaging.processor_concurrency` | - |
| `FLOW_ATTRIBUTION_CORRELATOR_ENABLED` | 1/0 | config |  | `messaging.flow_attribution_correlator_enabled` | - |
| `FLOW_ATTRIBUTION_CORRELATOR_INTERVAL_MS` | 1/0 | config |  | `messaging.flow_attribution_correlator_interval_ms` | - |
| `NATS_CERT_NAME` | 1/0 | config |  | `messaging.cert_name` | helm |
| `NATS_CREDS_FILE` | 3/0 | config |  | `messaging.creds_file` | helm |
| `NATS_ENABLED` | 4/0 | config |  | `messaging.enabled` | helm |
| `NATS_SERVER_NAME` | 3/0 | config |  | nats.server_name | helm |
| `NATS_TEST_CERT_DIR` | 1/0 | material |  | secret: `messaging.test_cert_dir` | - |
| `NATS_TEST_HOST` | 1/0 | config |  | database.host | - |
| `NATS_TEST_PORT` | 1/0 | config |  | `messaging.test_port` | - |
| `NATS_TEST_SERVER_NAME` | 1/0 | config |  | `messaging.test_server_name` | - |
| `NATS_TLS` | 3/0 | config |  | `messaging.tls` | helm |
| `NATS_URL` | 5/0 | config |  | nats.url | docker,helm |
| `NATS_USER` | 3/0 | config |  | `messaging.user` | - |
| `NETFLOW_CACHE_SCHEDULER_ENABLED` | 1/0 | config |  | `messaging.netflow_cache_scheduler_enabled` | - |
| `NETFLOW_SECURITY_REFRESH_CACHE_TTL_SECONDS` | 2/0 | config |  | `messaging.netflow_security_refresh_cache_ttl_seconds` | - |
| `NETFLOW_SECURITY_REFRESH_INTERVAL_SECONDS` | 4/0 | config |  | `messaging.netflow_security_refresh_interval_seconds` | - |
| `NETFLOW_SECURITY_SCHEDULER_ENABLED` | 1/0 | config |  | `messaging.netflow_security_scheduler_enabled` | - |
| `NETFLOW_SECURITY_THREAT_CANDIDATE_LIMIT` | 1/0 | config |  | `messaging.netflow_security_threat_candidate_limit` | - |
| `SERVICERADAR_NATS_URL` | 1/0 | config | `NATS_URL` | nats.url | - |
| `SWEEP_SRQL_PAGE_LIMIT` | 1/0 | config |  | `messaging.sweep_srql_page_limit` | - |
| `SYNC_INGESTOR_ASYNC` | 1/0 | config |  | `messaging.async` | helm |
| `SYNC_INGESTOR_BATCH_CONCURRENCY` | 1/0 | config |  | `messaging.batch_concurrency` | helm |
| `SYNC_INGESTOR_COALESCE_MS` | 1/0 | config |  | `messaging.coalesce_ms` | helm |
| `SYNC_INGESTOR_MAX_INFLIGHT` | 1/0 | config |  | `messaging.max_inflight` | helm |
| `SYNC_INGESTOR_QUEUE_MAX_CHUNKS` | 1/0 | config |  | `messaging.queue_max_chunks` | helm |

### 6.5 `integrations` -- 56 names, 8 secrets, 76 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `ADVISORY_FEED_SCHEDULER_ENABLED` | 1/0 | config |  | `integrations.advisory_feed_scheduler_enabled` | helm |
| `ANSIBLE_CATALOG_BASE_DIR` | 1/0 | config |  | `integrations.ansible_catalog_base_dir` | helm |
| `ANSIBLE_LIFECYCLE_SCHEDULER_ENABLED` | 1/0 | config |  | `integrations.ansible_lifecycle_scheduler_enabled` | - |
| `ANSIBLE_RETENTION_INTERVAL_SECONDS` | 1/0 | config |  | `integrations.ansible_retention_interval_seconds` | helm |
| `ANSIBLE_RETENTION_RUN_DETAIL_DAYS` | 1/0 | config |  | `integrations.ansible_retention_run_detail_days` | helm |
| `ANSIBLE_RETENTION_RUN_SUMMARY_DAYS` | 1/0 | config |  | `integrations.ansible_retention_run_summary_days` | helm |
| `ARMIS_E2E_ARTIFACT_DIR` | 1/0 | config |  | `integrations.e2e_artifact_dir` | scripts |
| `ARMIS_E2E_FAKER_URL` | 1/0 | config |  | `integrations.e2e_faker_url` | scripts |
| `ARMIS_E2E_FIXTURE_FILE` | 1/0 | config |  | `integrations.e2e_fixture_file` | scripts |
| `ARMIS_NORTHBOUND_SCHEDULER_ENABLED` | 1/0 | config |  | `integrations.northbound_scheduler_enabled` | - |
| `AWX_CONTROLLER_HEALTH_INTERVAL_SECONDS` | 1/0 | config |  | `integrations.awx_controller_health_interval_seconds` | helm |
| `AWX_RUN_WATCHDOG_INTERVAL_SECONDS` | 1/0 | config |  | `integrations.awx_run_watchdog_interval_seconds` | helm |
| `AWX_SCHEDULE_EVALUATOR_INTERVAL_SECONDS` | 1/0 | config |  | `integrations.awx_schedule_evaluator_interval_seconds` | helm |
| `GH_TOKEN` | 2/0 | secret | `GITHUB_TOKEN` | secret: `integrations.github_token` | - |
| `GITHUB_TOKEN` | 3/0 | secret |  | secret: `integrations.github_token` | - |
| `SERVICERADAR_ADVISORY_FEEDS_ENABLED` | 1/0 | config |  | `integrations.advisory_feeds_enabled` | helm |
| `SERVICERADAR_ADVISORY_NIST_NVD2_ENABLED` | 1/0 | config |  | `integrations.advisory_nist_nvd2_enabled` | helm |
| `SERVICERADAR_ADVISORY_STAGING_DIR` | 1/2 | config |  | `integrations.advisory_staging_dir` | helm |
| `SERVICERADAR_ARMIS_API_KEY` | 1/0 | secret |  | secret: `integrations.api_key` | - |
| `SERVICERADAR_ARMIS_API_SECRET` | 1/0 | secret |  | secret: `integrations.api_secret` | - |
| `SERVICERADAR_ARMIS_API_URL` | 1/0 | config |  | `integrations.api_url` | - |
| `SERVICERADAR_ARMIS_CUSTOM_FIELD` | 1/0 | config |  | `integrations.custom_field` | - |
| `SERVICERADAR_ARMIS_DEVICE_IP` | 1/0 | config |  | `integrations.device_ip` | - |
| `SERVICERADAR_ARMIS_NORTHBOUND_VALUE` | 1/0 | config |  | `integrations.northbound_value` | - |
| `SERVICERADAR_ARMIS_SEARCH_AQL` | 1/0 | config |  | `integrations.search_aql` | - |
| `SERVICERADAR_ARMIS_SEARCH_MAX_PAGES` | 1/0 | config |  | `integrations.search_max_pages` | - |
| `SERVICERADAR_AUTOMATION_CALLBACKS_ENABLED` | 3/2 | config |  | `integrations.callbacks_enabled` | helm |
| `SERVICERADAR_AUTOMATION_CALLBACK_AWX_CREDENTIAL_TYPE_ID` | 3/1 | config |  | `integrations.callback_awx_credential_type_id` | helm |
| `SERVICERADAR_AUTOMATION_CALLBACK_AWX_INJECTOR_DIGEST` | 3/0 | config |  | `integrations.callback_awx_injector_digest` | helm |
| `SERVICERADAR_AUTOMATION_CALLBACK_AWX_ORGANIZATION_ID` | 3/1 | config |  | `integrations.callback_awx_organization_id` | helm |
| `SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_FILE` | 3/2 | secret |  | secret: `integrations.callback_envelope_key_file` | helm |
| `SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_ID` | 3/2 | config |  | `integrations.callback_envelope_key_id` | helm |
| `SERVICERADAR_AUTOMATION_CALLBACK_HMAC_KEYRING_FILE` | 2/1 | config |  | `integrations.callback_hmac_keyring_file` | helm |
| `SERVICERADAR_AUTOMATION_CALLBACK_ORIGIN` | 2/1 | config |  | `integrations.callback_origin` | helm |
| `SERVICERADAR_AUTOMATION_CALLBACK_RESPONSE_POLICY_FILE` | 3/1 | config |  | `integrations.callback_response_policy_file` | helm |
| `SERVICERADAR_CISA_KEV_URL` | 1/0 | config |  | `integrations.cisa_kev_url` | - |
| `SERVICERADAR_NORTHBOUND_CALLBACK_BASE_URL` | 2/0 | config | `BASE_URL` | `integrations.base_url` | - |
| `SERVICERADAR_OTX_BACKOFF_MS` | 1/0 | config |  | `integrations.backoff_ms` | - |
| `SERVICERADAR_OTX_BASE_URL` | 1/0 | config |  | `integrations.base_url` | - |
| `SERVICERADAR_OTX_MAX_RETRIES` | 1/0 | config |  | `integrations.max_retries` | - |
| `SERVICERADAR_OTX_MODIFIED_SINCE` | 1/0 | config |  | `integrations.modified_since` | - |
| `SERVICERADAR_OTX_PAGE` | 1/0 | config |  | `integrations.page` | - |
| `SERVICERADAR_OTX_PAGE_SIZE` | 1/0 | config |  | `integrations.page_size` | - |
| `SERVICERADAR_OTX_PARTITION` | 1/0 | config |  | `integrations.partition` | helm |
| `SERVICERADAR_OTX_RAW_BUCKET` | 1/0 | config |  | `integrations.raw_bucket` | - |
| `SERVICERADAR_OTX_RAW_MAX_BUCKET_BYTES` | 1/0 | config |  | `integrations.raw_max_bucket_bytes` | - |
| `SERVICERADAR_OTX_RAW_MAX_CHUNK_BYTES` | 1/0 | config |  | `integrations.raw_max_chunk_bytes` | - |
| `SERVICERADAR_OTX_RAW_REPLICAS` | 1/0 | config |  | `integrations.raw_replicas` | - |
| `SERVICERADAR_OTX_RAW_STORAGE` | 1/0 | config |  | `integrations.raw_storage` | - |
| `SERVICERADAR_OTX_RAW_TTL_SECONDS` | 1/0 | config |  | `integrations.raw_ttl_seconds` | - |
| `SERVICERADAR_OTX_TIMEOUT_MS` | 1/0 | config |  | `integrations.timeout_ms` | - |
| `SERVICERADAR_PROXMOX_API_TOKEN` | 1/0 | secret |  | secret: `integrations.proxmox_api_token` | - |
| `SERVICERADAR_PROXMOX_INSECURE_SKIP_VERIFY` | 1/0 | config |  | `integrations.proxmox_insecure_skip_verify` | - |
| `SERVICERADAR_PROXMOX_TIMEOUT_MS` | 1/0 | config |  | `integrations.proxmox_timeout_ms` | - |
| `SERVICERADAR_VULNCHECK_TOKEN` | 1/0 | secret | `VULNCHECK_API_TOKEN` | secret: `integrations.vulncheck_api_token` | - |
| `VULNCHECK_API_TOKEN` | 1/0 | secret |  | secret: `integrations.vulncheck_api_token` | - |

### 6.6 `identity` -- 40 names, 3 secrets, 76 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `CORE_ADDRESS` | 1/0 | config |  | core.address | helm |
| `DATASVC_ADDRESS` | 1/0 | config |  | `identity.address` | helm |
| `DATASVC_CERT_DIR` | 4/0 | material |  | secret: `identity.cert_dir` | helm |
| `DATASVC_CERT_NAME` | 1/0 | config |  | `identity.cert_name` | helm |
| `DATASVC_ENABLED` | 2/0 | config |  | `identity.enabled` | helm |
| `DATASVC_HOST` | 1/0 | config |  | `identity.host` | helm |
| `DATASVC_PORT` | 1/0 | config |  | `identity.port` | helm |
| `DATASVC_SEC_MODE` | 2/0 | config |  | core.security_mode | helm |
| `DATASVC_SERVER_NAME` | 2/0 | config |  | core.server_name | helm |
| `DATASVC_SPIFFE_CERT_DIR` | 2/0 | material | `DATASVC_CERT_DIR` | secret: `identity.cert_dir` | - |
| `DATASVC_SSL` | 2/0 | config |  | `identity.ssl` | helm |
| `DATASVC_TIMEOUT` | 1/0 | config |  | `identity.timeout` | - |
| `KUBERNETES_NODE_BASENAME` | 4/0 | config |  | `identity.kubernetes_node_basename` | helm |
| `KUBERNETES_SELECTOR` | 4/0 | config |  | `identity.kubernetes_selector` | helm |
| `SERVICERADAR_CORE_ADDRESS` | 1/0 | config | `CORE_ADDRESS` | core.address | - |
| `SERVICERADAR_CORE_MAILER_ADAPTER` | 1/0 | config | `SERVICERADAR_MAILER_ADAPTER` | `identity.mailer_adapter` | - |
| `SERVICERADAR_CORE_METRICS_ENABLED` | 1/0 | config |  | `identity.metrics_enabled` | - |
| `SERVICERADAR_CORE_METRICS_PORT` | 1/0 | config |  | `identity.metrics_port` | - |
| `SERVICERADAR_CORE_OBAN_ENABLED` | 1/0 | config |  | `identity.oban_enabled` | helm |
| `SERVICERADAR_CORE_REGISTRIES_ENABLED` | 1/0 | config |  | `identity.registries_enabled` | helm |
| `SERVICERADAR_CORE_REPO_ENABLED` | 2/0 | config |  | `identity.repo_enabled` | helm |
| `SERVICERADAR_CORE_RUN_MIGRATIONS` | 2/0 | config |  | `identity.run_migrations` | helm,scripts |
| `SERVICERADAR_CORE_VAULT_ENABLED` | 1/0 | config |  | `identity.vault_enabled` | helm |
| `SERVICERADAR_SECURITY_MODE` | 1/0 | config |  | `identity.security_mode` | - |
| `SERVICERADAR_WORKLOAD_IDENTITY_ADDON_ARTIFACTS` | 1/0 | config |  | `identity.workload_identity_addon_artifacts` | helm |
| `SERVICERADAR_WORKLOAD_IDENTITY_ADDON_OCI_DIGEST` | 1/0 | config |  | `identity.workload_identity_addon_oci_digest` | helm |
| `SERVICERADAR_WORKLOAD_IDENTITY_ADDON_OCI_REF` | 1/0 | config |  | `identity.workload_identity_addon_oci_ref` | helm |
| `SERVICERADAR_WORKLOAD_IDENTITY_ADDON_VERSION` | 1/0 | config |  | `identity.workload_identity_addon_version` | helm |
| `SERVICERADAR_WORKLOAD_IDENTITY_SKIP_GUARD` | 1/0 | config |  | `identity.workload_identity_skip_guard` | - |
| `SERVICERADAR_WORKLOAD_IDENTITY_SKIP_GUARD_HEARTBEAT_MS` | 1/0 | config |  | `identity.workload_identity_skip_guard_heartbeat_ms` | - |
| `SPIFFE_CERT_CRITICAL_SECONDS` | 1/0 | config |  | `identity.cert_critical_seconds` | - |
| `SPIFFE_CERT_DIR` | 10/0 | material |  | secret: `identity.cert_dir` | helm |
| `SPIFFE_CERT_MONITOR_ENABLED` | 1/0 | config |  | `identity.cert_monitor_enabled` | - |
| `SPIFFE_CERT_MONITOR_INTERVAL_SECONDS` | 1/0 | config |  | `identity.cert_monitor_interval_seconds` | - |
| `SPIFFE_CERT_WARN_SECONDS` | 1/0 | config |  | `identity.cert_warn_seconds` | - |
| `SPIFFE_ENDPOINT_SOCKET` | 1/0 | config | `SPIFFE_WORKLOAD_API_SOCKET` | core.workload_socket | helm |
| `SPIFFE_MODE` | 4/0 | config |  | `identity.mode` | helm |
| `SPIFFE_TRUST_BUNDLE_PATH` | 3/0 | config |  | `identity.trust_bundle_path` | helm |
| `SPIFFE_TRUST_DOMAIN` | 4/0 | config |  | core.trust_domain | helm |
| `SPIFFE_WORKLOAD_API_SOCKET` | 4/0 | config |  | core.workload_socket | helm |

### 6.7 `cluster` -- 24 names, 1 secrets, 66 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `CLUSTER_CORE_DNS_QUERY` | 2/0 | config |  | `cluster.core_dns_query` | helm |
| `CLUSTER_CORE_NODE_BASENAME` | 6/0 | config |  | `cluster.core_node_basename` | helm |
| `CLUSTER_CORE_SERVICE` | 1/0 | config |  | `cluster.core_service` | helm |
| `CLUSTER_DNS_QUERY` | 4/0 | config |  | `cluster.dns_query` | helm |
| `CLUSTER_ENABLED` | 7/0 | config |  | `cluster.enabled` | helm |
| `CLUSTER_GATEWAY_DNS_QUERY` | 2/0 | config |  | `cluster.gateway_dns_query` | helm |
| `CLUSTER_GATEWAY_NODE_BASENAME` | 3/0 | config |  | `cluster.gateway_node_basename` | helm |
| `CLUSTER_GATEWAY_SERVICE` | 1/0 | config |  | `cluster.gateway_service` | helm |
| `CLUSTER_GOSSIP_PORT` | 4/0 | config |  | `cluster.gossip_port` | - |
| `CLUSTER_GOSSIP_SECRET` | 4/0 | secret |  | secret: `cluster.gossip_secret` | - |
| `CLUSTER_HOSTS` | 5/0 | config |  | `cluster.hosts` | - |
| `CLUSTER_NODE_BASENAME` | 4/0 | config |  | `cluster.node_basename` | helm |
| `CLUSTER_STRATEGY` | 4/0 | config |  | `cluster.strategy` | helm |
| `CLUSTER_WEB_DNS_QUERY` | 1/0 | config |  | `cluster.web_dns_query` | helm |
| `CLUSTER_WEB_NODE_BASENAME` | 2/0 | config |  | `cluster.web_node_basename` | helm |
| `CLUSTER_WEB_SERVICE` | 1/0 | config |  | `cluster.web_service` | helm |
| `DNS_CLUSTER_QUERY` | 1/0 | config |  | `cluster.dns_cluster_query` | - |
| `DOCKER_NETWORK` | 1/0 | config |  | `cluster.docker_network` | - |
| `ENABLE_TLS_DIST` | 1/0 | config |  | `cluster.enable_tls_dist` | - |
| `NAMESPACE` | 4/0 | config |  | `cluster.namespace` | bazel,helm,scripts |
| `NODE_IP` | 1/0 | config |  | `cluster.node_ip` | helm |
| `SERVICERADAR_CLUSTER_COORDINATOR` | 2/0 | config |  | `cluster.coordinator` | helm |
| `SERVICERADAR_HORDE_SYNC_INTERVAL_MS` | 1/0 | config |  | `cluster.horde_sync_interval_ms` | - |
| `SERVICERADAR_HOSTED_CLUSTER_CONTRACT` | 4/0 | config |  | `cluster.hosted_cluster_contract` | - |

### 6.8 `web` -- 56 names, 8 secrets, 60 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `ADMIN_API_BASE_URL` | 1/0 | config |  | `web.admin_api_base_url` | - |
| `ADMIN_BASIC_AUTH_PASSWORD` | 1/0 | secret |  | secret: `web.admin_basic_auth_password` | - |
| `ADMIN_BASIC_AUTH_USERNAME` | 1/0 | config |  | `web.admin_basic_auth_username` | - |
| `BASE_URL` | 2/0 | config |  | `web.base_url` | - |
| `CLI_AUTH_SCHEDULER_ENABLED` | 1/0 | config |  | `web.cli_auth_scheduler_enabled` | - |
| `COMPOSITE_VISUAL_CAPTURE_DIR` | 1/0 | config |  | `web.composite_visual_capture_dir` | - |
| `DEV_SECRET_KEY_BASE` | 1/0 | secret | `SECRET_KEY_BASE` | secret: `web.secret_key_base` | - |
| `PHX_CHECK_ORIGIN` | 1/0 | config |  | `web.check_origin` | helm |
| `PHX_HOST` | 1/0 | config |  | `web.host` | helm |
| `PHX_PORT` | 1/0 | config |  | `web.port` | - |
| `PHX_SERVER` | 1/0 | config |  | `web.server` | helm |
| `PORT` | 1/0 | config |  | `web.port` | docker,helm |
| `REACT_RENDER_PORT` | 1/0 | config |  | `web.react_render_port` | - |
| `SECRET_KEY_BASE` | 2/0 | secret |  | secret: `web.secret_key_base` | helm |
| `SERVICERADAR_ADMIN_EMAIL` | 1/2 | config |  | `web.admin_email` | helm |
| `SERVICERADAR_ADMIN_PASSWORD` | 1/4 | secret |  | secret: `web.admin_password` | helm,scripts |
| `SERVICERADAR_ADMIN_PASSWORD_FILE` | 1/0 | secret | `SERVICERADAR_ADMIN_PASSWORD` | secret: `web.admin_password` | - |
| `SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC` | 1/2 | config |  | `web.admin_password_force_sync` | helm |
| `SERVICERADAR_API_KEY` | 2/0 | secret |  | secret: `web.api_key` | helm |
| `SERVICERADAR_API_KEYS` | 1/0 | secret | `SERVICERADAR_API_KEY` | secret: `web.api_key` | - |
| `SERVICERADAR_AUTH_DISABLE_SSO` | 1/0 | config |  | `web.auth_disable_sso` | helm |
| `SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN` | 1/0 | config |  | `web.auth_force_local_login` | helm |
| `SERVICERADAR_DASHBOARD_REPORTS_ENABLED` | 1/0 | config |  | `web.dashboard_reports_enabled` | - |
| `SERVICERADAR_DASHBOARD_REPORT_SCANNER_CRON` | 1/0 | config |  | `web.dashboard_report_scanner_cron` | - |
| `SERVICERADAR_DASHBOARD_REPORT_SCANNER_LIMIT` | 1/0 | config |  | `web.dashboard_report_scanner_limit` | - |
| `SERVICERADAR_DEV_ROUTES` | 1/0 | config |  | `web.dev_routes` | helm |
| `SERVICERADAR_GOD_VIEW_ENABLED` | 1/0 | config |  | `web.god_view_enabled` | helm |
| `SERVICERADAR_GOD_VIEW_RUNTIME_GRAPH_REFRESH_MS` | 1/0 | config |  | `web.god_view_runtime_graph_refresh_ms` | helm |
| `SERVICERADAR_GOD_VIEW_SNAPSHOT_BUDGET_MS` | 1/0 | config |  | `web.god_view_snapshot_budget_ms` | helm |
| `SERVICERADAR_GOD_VIEW_SNAPSHOT_COALESCE_MS` | 1/0 | config |  | `web.god_view_snapshot_coalesce_ms` | helm |
| `SERVICERADAR_LOCAL_LOG_LEVEL` | 1/0 | config |  | `web.local_log_level` | - |
| `SERVICERADAR_LOCAL_MAILER` | 1/3 | config |  | `web.local_mailer` | helm |
| `SERVICERADAR_MANAGED_DEVICE_LIMIT` | 1/0 | config | `SERVICERADAR_MAX_DEVICES` | `web.max_devices` | - |
| `SERVICERADAR_MAX_DEVICES` | 2/0 | config |  | `web.max_devices` | helm |
| `SERVICERADAR_SESSION_ABSOLUTE_TIMEOUT_SECONDS` | 1/0 | config |  | `web.session_absolute_timeout_seconds` | - |
| `SERVICERADAR_SESSION_IDLE_TIMEOUT_SECONDS` | 1/0 | config |  | `web.session_idle_timeout_seconds` | - |
| `SERVICERADAR_TRUSTED_PROXY_CIDRS` | 1/0 | config |  | `web.trusted_proxy_cidrs` | - |
| `SERVICERADAR_TRUST_X_FORWARDED_FOR` | 1/0 | config |  | `web.trust_x_forwarded_for` | - |
| `SERVICERADAR_WEB_NG_ASSET_WATCHERS` | 1/0 | config |  | `web.asset_watchers` | - |
| `SERVICERADAR_WEB_NG_CODE_RELOADER` | 1/0 | config |  | `web.code_reloader` | - |
| `SERVICERADAR_WEB_NG_LIVE_RELOAD` | 1/0 | config |  | `web.live_reload` | - |
| `SERVICERADAR_WEB_NG_OBAN_ENABLED` | 1/0 | config |  | `web.oban_enabled` | helm |
| `SESSION_COOKIE_SECURE` | 1/0 | config |  | `web.session_cookie_secure` | - |
| `SESSION_ENCRYPTION_SALT` | 1/0 | config |  | `web.session_encryption_salt` | - |
| `SESSION_SIGNING_SALT` | 1/0 | config |  | `web.session_signing_salt` | - |
| `TOKEN_SIGNING_SECRET` | 1/0 | secret |  | secret: `web.token_signing_secret` | - |
| `WEB_NG_OBAN_NOTIFIER` | 1/0 | config |  | `web.oban_notifier` | helm |
| `WEB_NG_OBAN_QUEUE_ALERTS` | 1/0 | config |  | `web.oban_queue_alerts` | helm |
| `WEB_NG_OBAN_QUEUE_EDGE` | 1/0 | config |  | `web.oban_queue_edge` | helm |
| `WEB_NG_OBAN_QUEUE_EVENTS` | 1/0 | config |  | `web.oban_queue_events` | helm |
| `WEB_NG_OBAN_QUEUE_INTEGRATIONS` | 1/0 | config |  | `web.oban_queue_integrations` | helm |
| `WEB_NG_OBAN_QUEUE_NOTIFICATIONS` | 1/0 | config |  | `web.oban_queue_notifications` | helm |
| `WEB_NG_OBAN_QUEUE_ONBOARDING` | 1/0 | config |  | `web.oban_queue_onboarding` | helm |
| `WEB_NG_OBAN_QUEUE_SERVICE_CHECKS` | 1/0 | config |  | `web.oban_queue_service_checks` | helm |
| `WEB_NG_OBAN_QUEUE_SWEEPS` | 1/0 | config |  | `web.oban_queue_sweeps` | helm |
| `WEB_NG_OBAN_QUEUE_WEB_MAINTENANCE` | 1/0 | config |  | `web.oban_queue_web_maintenance` | helm |

### 6.9 `jobs` -- 34 names, 0 secrets, 54 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `OBAN_LIFELINE_RESCUE_AFTER_MS` | 2/0 | config |  | `jobs.lifeline_rescue_after_ms` | - |
| `OBAN_NODE` | 2/0 | config |  | `jobs.node` | - |
| `OBAN_NOTIFIER` | 2/0 | config |  | `jobs.notifier` | helm |
| `OBAN_PERIODIC_JOB_STALE_MINUTES` | 1/0 | config |  | `jobs.periodic_job_stale_minutes` | - |
| `OBAN_QUEUE_ALERTS` | 2/0 | config |  | `jobs.queue_alerts` | helm |
| `OBAN_QUEUE_ANSIBLE_CATALOG` | 2/0 | config |  | `jobs.queue_ansible_catalog` | - |
| `OBAN_QUEUE_ANSIBLE_PULSE` | 2/0 | config |  | `jobs.queue_ansible_pulse` | - |
| `OBAN_QUEUE_ANSIBLE_RETENTION` | 2/0 | config |  | `jobs.queue_ansible_retention` | - |
| `OBAN_QUEUE_DEFAULT` | 2/0 | config |  | `jobs.queue_default` | helm |
| `OBAN_QUEUE_EDGE` | 2/0 | config |  | `jobs.queue_edge` | helm |
| `OBAN_QUEUE_EVENTS` | 2/0 | config |  | `jobs.queue_events` | helm |
| `OBAN_QUEUE_INTEGRATIONS` | 2/0 | config |  | `jobs.queue_integrations` | helm |
| `OBAN_QUEUE_MAINTENANCE` | 2/0 | config |  | `jobs.queue_maintenance` | helm |
| `OBAN_QUEUE_MONITORING` | 2/0 | config |  | `jobs.queue_monitoring` | helm |
| `OBAN_QUEUE_NATS_ACCOUNTS` | 2/0 | config |  | `jobs.queue_nats_accounts` | helm |
| `OBAN_QUEUE_NOTIFICATIONS` | 2/0 | config |  | `jobs.queue_notifications` | helm |
| `OBAN_QUEUE_ONBOARDING` | 2/0 | config |  | `jobs.queue_onboarding` | helm |
| `OBAN_QUEUE_SERVICE_CHECKS` | 2/0 | config |  | `jobs.queue_service_checks` | helm |
| `OBAN_QUEUE_SWEEPS` | 2/0 | config |  | `jobs.queue_sweeps` | helm |
| `OBAN_SCHEMA` | 1/0 | config |  | `jobs.schema` | - |
| `SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION_CRON` | 1/0 | config |  | `jobs.anomaly_edge_config_projection_cron` | - |
| `SERVICERADAR_ANOMALY_LIVENESS_CRON` | 1/0 | config |  | `jobs.anomaly_liveness_cron` | - |
| `SERVICERADAR_ANOMALY_SILENCE_TRIPWIRE_CRON` | 1/0 | config |  | `jobs.anomaly_silence_tripwire_cron` | - |
| `SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED` | 1/0 | config |  | `jobs.ash_oban_scheduler_enabled` | helm |
| `SERVICERADAR_CAPACITY_FORECASTING_CRON` | 2/0 | config |  | `jobs.capacity_forecasting_cron` | helm |
| `SERVICERADAR_CREDENTIAL_BROKER_RETENTION_CRON` | 2/0 | config |  | `jobs.credential_broker_retention_cron` | - |
| `SERVICERADAR_NOTIFICATION_CONTINUATION_CRON` | 1/0 | config |  | `jobs.notification_continuation_cron` | - |
| `SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_CRON` | 1/0 | config |  | `jobs.notification_delivery_retention_cron` | - |
| `SERVICERADAR_NOTIFICATION_RECEIPT_SWEEP_CRON` | 1/0 | config |  | `jobs.notification_receipt_sweep_cron` | - |
| `SERVICERADAR_NOTIFICATION_SILENCE_SWEEP_CRON` | 1/0 | config |  | `jobs.notification_silence_sweep_cron` | - |
| `SERVICERADAR_OBSERVABILITY_RETENTION_CRON` | 1/0 | config |  | `jobs.observability_retention_cron` | helm |
| `SERVICERADAR_SEASONAL_BASELINE_TRIPWIRE_CRON` | 1/0 | config |  | `jobs.seasonal_baseline_tripwire_cron` | - |
| `SERVICERADAR_SEASONAL_DISPOSITION_CRON` | 1/0 | config |  | `jobs.seasonal_disposition_cron` | - |
| `SERVICERADAR_SEASONAL_EDGE_BASELINE_CRON` | 1/0 | config |  | `jobs.seasonal_edge_baseline_cron` | - |

### 6.10 `analysis` -- 38 names, 0 secrets, 53 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `ALERT_RETENTION_BATCH_SIZE` | 1/0 | config |  | `analysis.alert_retention_batch_size` | - |
| `ALERT_RETENTION_CRON` | 2/0 | config |  | `analysis.alert_retention_cron` | - |
| `ALERT_RETENTION_DAYS` | 1/0 | config |  | `analysis.alert_retention_days` | - |
| `ALERT_RETENTION_MAX_BATCHES` | 1/0 | config |  | `analysis.alert_retention_max_batches` | - |
| `DEVICE_ENRICHMENT_RULES_DIR` | 2/0 | config |  | `analysis.device_enrichment_rules_dir` | helm |
| `IP_ENRICHMENT_SCHEDULER_ENABLED` | 1/0 | config |  | `analysis.ip_enrichment_scheduler_enabled` | - |
| `MTR_AUTOMATION_BASELINE_ENABLED` | 2/0 | config |  | `analysis.automation_baseline_enabled` | helm |
| `MTR_AUTOMATION_CONSENSUS_ENABLED` | 2/0 | config |  | `analysis.automation_consensus_enabled` | helm |
| `MTR_AUTOMATION_ENABLED` | 1/0 | config |  | `analysis.automation_enabled` | helm |
| `MTR_AUTOMATION_TRIGGER_ENABLED` | 2/0 | config |  | `analysis.automation_trigger_enabled` | helm |
| `MTR_BASELINE_TICK_MS` | 1/0 | config |  | `analysis.baseline_tick_ms` | helm |
| `MTR_CONSENSUS_COHORT_RETENTION_MS` | 1/0 | config |  | `analysis.consensus_cohort_retention_ms` | helm |
| `MTR_GRAPH_PRUNE_INTERVAL_MS` | 1/0 | config |  | `analysis.graph_prune_interval_ms` | - |
| `MTR_RETENTION_DAYS` | 2/0 | config |  | `analysis.retention_days` | helm |
| `PREFIX_TAG_BENCH_MULTI_SOURCE` | 1/0 | config |  | `analysis.prefix_tag_bench_multi_source` | - |
| `PREFIX_TAG_BENCH_SIZE` | 1/0 | config |  | `analysis.prefix_tag_bench_size` | - |
| `SERVICERADAR_CAPACITY_FORECASTING_EMIT_VERDICTS` | 2/0 | config |  | `analysis.capacity_forecasting_emit_verdicts` | helm |
| `SERVICERADAR_CAPACITY_FORECASTING_ENABLED` | 2/0 | config |  | `analysis.capacity_forecasting_enabled` | helm |
| `SERVICERADAR_CAPACITY_FORECASTING_HORIZON_SECONDS` | 2/0 | config |  | `analysis.capacity_forecasting_horizon_seconds` | helm |
| `SERVICERADAR_CAPACITY_FORECASTING_MIN_POINTS` | 2/0 | config |  | `analysis.capacity_forecasting_min_points` | helm |
| `SERVICERADAR_CAPACITY_FORECASTING_SEASONAL_PERIOD` | 2/0 | config |  | `analysis.capacity_forecasting_seasonal_period` | helm |
| `SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS` | 1/2 | config |  | `analysis.capacity_forecasting_source_opt_ins` | - |
| `SERVICERADAR_CAPACITY_FORECASTING_WARNING_HORIZON_SECONDS` | 2/0 | config |  | `analysis.capacity_forecasting_warning_horizon_seconds` | helm |
| `SERVICERADAR_GEO_TAG_DERIVATION_ENABLED` | 1/0 | config |  | `analysis.geo_tag_derivation_enabled` | - |
| `SERVICERADAR_MAPPER_TOPOLOGY_EDGE_STALE_MINUTES` | 2/0 | config |  | `analysis.mapper_topology_edge_stale_minutes` | helm |
| `SERVICERADAR_PREFIX_TAGS_LOADER_ENABLED` | 1/0 | config |  | `analysis.prefix_tags_loader_enabled` | - |
| `SERVICERADAR_PREFIX_TAG_ENRICHMENT_ENABLED` | 1/0 | config |  | `analysis.prefix_tag_enrichment_enabled` | - |
| `SERVICERADAR_PREFIX_TAG_PROVIDER_TRIE_ENABLED` | 1/0 | config |  | `analysis.prefix_tag_provider_trie_enabled` | - |
| `SERVICERADAR_THREAT_INTEL_ENGINE_MATCH_ENABLED` | 1/0 | config |  | `analysis.threat_intel_engine_match_enabled` | - |
| `SERVICERADAR_TOPOLOGY_CANONICAL_PRUNE_GUARD_OVERRIDE` | 1/0 | config |  | `analysis.canonical_prune_guard_override` | - |
| `SERVICERADAR_TOPOLOGY_CANONICAL_PRUNE_MAX_PERCENT` | 1/0 | config |  | `analysis.canonical_prune_max_percent` | - |
| `SERVICERADAR_TOPOLOGY_CANONICAL_REBUILD_HEARTBEAT_MS` | 1/0 | config |  | `analysis.canonical_rebuild_heartbeat_ms` | - |
| `SERVICERADAR_TOPOLOGY_CANONICAL_REBUILD_MIN_UPSERT_FLOOR` | 1/0 | config |  | `analysis.canonical_rebuild_min_upsert_floor` | - |
| `SERVICERADAR_TOPOLOGY_ENDPOINT_IDENTITY_PROMOTION` | 1/0 | config |  | `analysis.endpoint_identity_promotion` | helm |
| `SERVICERADAR_TOPOLOGY_LINK_RETENTION_DAYS` | 2/0 | config |  | `analysis.link_retention_days` | helm |
| `SERVICERADAR_TOPOLOGY_V2_CONSUMPTION_ENABLED` | 1/0 | config |  | `analysis.v2_consumption_enabled` | - |
| `SERVICERADAR_ZEN_RULE_TEMPLATE_DIRS` | 2/1 | config |  | `analysis.zen_rule_template_dirs` | - |
| `TOPOLOGY_STATE_SCHEDULER_ENABLED` | 1/0 | config |  | `analysis.topology_state_scheduler_enabled` | - |

### 6.11 `plugins` -- 36 names, 4 secrets, 47 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `BUMBLEBEE_CATALOG_REFRESH_ENABLED` | 2/0 | config |  | `plugins.bumblebee_catalog_refresh_enabled` | - |
| `PLUGIN_ALLOW_UNSIGNED_UPLOADS` | 1/0 | config |  | `plugins.allow_unsigned_uploads` | - |
| `PLUGIN_REQUIRE_GPG_FOR_GITHUB` | 1/0 | config |  | `plugins.require_gpg_for_github` | - |
| `PLUGIN_STORAGE_BACKEND` | 1/0 | config |  | `plugins.storage_backend` | helm |
| `PLUGIN_STORAGE_BUCKET` | 1/0 | config |  | `plugins.storage_bucket` | helm |
| `PLUGIN_STORAGE_DOWNLOAD_TTL_SECONDS` | 5/0 | config |  | `plugins.storage_download_ttl_seconds` | helm |
| `PLUGIN_STORAGE_JS_MAX_BUCKET_BYTES` | 1/0 | config |  | `plugins.storage_js_max_bucket_bytes` | - |
| `PLUGIN_STORAGE_JS_MAX_CHUNK_BYTES` | 1/0 | config |  | `plugins.storage_js_max_chunk_bytes` | - |
| `PLUGIN_STORAGE_JS_REPLICAS` | 1/0 | config |  | `plugins.storage_js_replicas` | helm |
| `PLUGIN_STORAGE_JS_STORAGE` | 1/0 | config |  | `plugins.storage_js_storage` | - |
| `PLUGIN_STORAGE_JS_TTL_SECONDS` | 1/0 | config |  | `plugins.storage_js_ttl_seconds` | - |
| `PLUGIN_STORAGE_MAX_UPLOAD_BYTES` | 1/0 | config |  | `plugins.storage_max_upload_bytes` | - |
| `PLUGIN_STORAGE_PATH` | 1/0 | config |  | `plugins.storage_path` | helm |
| `PLUGIN_STORAGE_PUBLIC_URL` | 4/0 | config |  | `plugins.storage_public_url` | helm |
| `PLUGIN_STORAGE_SIGNING_SECRET` | 4/0 | secret |  | secret: `plugins.storage_signing_secret` | helm |
| `PLUGIN_STORAGE_UPLOAD_TTL_SECONDS` | 1/0 | config |  | `plugins.storage_upload_ttl_seconds` | - |
| `PLUGIN_TRUSTED_GITHUB_OWNERS` | 1/0 | config |  | `plugins.trusted_github_owners` | - |
| `PLUGIN_TRUSTED_GITHUB_REPOSITORIES` | 1/0 | config |  | `plugins.trusted_github_repositories` | - |
| `PLUGIN_TRUSTED_GITHUB_SIGNERS` | 1/0 | config |  | `plugins.trusted_github_signers` | - |
| `PLUGIN_TRUSTED_UPLOAD_SIGNING_KEYS` | 1/0 | secret |  | secret: `plugins.trusted_upload_signing_keys` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_AUTO_SYNC` | 1/0 | config |  | `plugins.auto_sync` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_COSIGN_BINARY` | 1/0 | config |  | `plugins.cosign_binary` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_COSIGN_PUBLIC_KEY` | 1/0 | material |  | secret: `plugins.cosign_public_key` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_COSIGN_PUBLIC_KEY_FILE` | 1/0 | material | `SERVICERADAR_FIRST_PARTY_PLUGIN_COSIGN_PUBLIC_KEY` | secret: `plugins.cosign_public_key` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_INDEX_ASSET` | 1/0 | config |  | `plugins.index_asset` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_REGISTRY_DOCKER_CONFIG_FILE` | 1/0 | config |  | `plugins.registry_docker_config_file` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_REGISTRY_DOCKER_CONFIG_JSON` | 1/0 | config |  | `plugins.registry_docker_config_json` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_REPO_URL` | 1/0 | config |  | `plugins.repo_url` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_SYNC_INTERVAL_SECONDS` | 1/0 | config |  | `plugins.sync_interval_seconds` | helm |
| `SERVICERADAR_FIRST_PARTY_PLUGIN_SYNC_LIMIT` | 1/0 | config |  | `plugins.sync_limit` | helm |
| `SERVICERADAR_NATIVE_ADDON_AUTO_APPROVE_IDS` | 1/0 | config |  | `plugins.native_addon_auto_approve_ids` | helm |
| `SERVICERADAR_NATIVE_ADDON_AUTO_SYNC` | 1/0 | config |  | `plugins.native_addon_auto_sync` | helm |
| `SERVICERADAR_NATIVE_ADDON_INDEX_ASSET` | 1/0 | config |  | `plugins.native_addon_index_asset` | helm |
| `SERVICERADAR_NATIVE_ADDON_REPO_URL` | 1/0 | config |  | `plugins.native_addon_repo_url` | helm |
| `SERVICERADAR_NATIVE_ADDON_SYNC_INTERVAL_SECONDS` | 1/0 | config |  | `plugins.native_addon_sync_interval_seconds` | helm |
| `SERVICERADAR_NATIVE_ADDON_SYNC_LIMIT` | 1/0 | config |  | `plugins.native_addon_sync_limit` | helm |

### 6.12 `cold_tier` -- 38 names, 4 secrets, 43 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `OBJECT_STORE_RETENTION_AGENT_RELEASE_KEEP_LATEST` | 1/0 | config |  | `cold_tier.object_store_retention_agent_release_keep_latest` | helm |
| `OBJECT_STORE_RETENTION_CRON` | 2/0 | config |  | `cold_tier.object_store_retention_cron` | helm |
| `OBJECT_STORE_RETENTION_DATASVC_TIMEOUT_MS` | 1/0 | config |  | `cold_tier.object_store_retention_datasvc_timeout_ms` | helm |
| `OBJECT_STORE_RETENTION_DRY_RUN` | 2/0 | config |  | `cold_tier.object_store_retention_dry_run` | helm |
| `OBJECT_STORE_RETENTION_ENABLED` | 3/0 | config |  | `cold_tier.object_store_retention_enabled` | helm |
| `OBJECT_STORE_RETENTION_NATIVE_ADDON_ORPHAN_GRACE_SECONDS` | 1/0 | config |  | `cold_tier.object_store_retention_native_addon_orphan_grace_seconds` | helm |
| `OBJECT_STORE_RETENTION_PLUGIN_ORPHAN_GRACE_SECONDS` | 1/0 | config |  | `cold_tier.object_store_retention_plugin_orphan_grace_seconds` | helm |
| `SERVICERADAR_COLD_EXPORT_LAG_HOURS` | 1/0 | config |  | `cold_tier.export_lag_hours` | - |
| `SERVICERADAR_COLD_QUARANTINE_ATTEMPTS` | 1/0 | config |  | `cold_tier.quarantine_attempts` | - |
| `SERVICERADAR_COLD_RUN_CHUNK_BUDGET` | 1/0 | config |  | `cold_tier.run_chunk_budget` | - |
| `SERVICERADAR_COLD_TIER_BUCKET_URL` | 1/0 | config |  | `cold_tier.bucket_url` | - |
| `SERVICERADAR_COLD_TIER_ENABLED` | 1/0 | config |  | `cold_tier.enabled` | - |
| `SERVICERADAR_COLD_TIER_HEAD_DATABASE` | 1/0 | config |  | `cold_tier.head_database` | - |
| `SERVICERADAR_COLD_TIER_HEAD_HOST` | 1/0 | config |  | `cold_tier.head_host` | - |
| `SERVICERADAR_COLD_TIER_HEAD_PASSWORD` | 1/0 | secret |  | secret: `cold_tier.head_password` | - |
| `SERVICERADAR_COLD_TIER_HEAD_PORT` | 1/0 | config |  | `cold_tier.head_port` | - |
| `SERVICERADAR_COLD_TIER_HEAD_USERNAME` | 1/0 | config |  | `cold_tier.head_username` | - |
| `SERVICERADAR_COLD_TIER_PRIMARY_DATABASE` | 1/0 | config |  | `cold_tier.primary_database` | - |
| `SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD` | 2/0 | secret |  | secret: `cold_tier.primary_fdw_password` | - |
| `SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD_FILE` | 1/0 | secret | `SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD` | secret: `cold_tier.primary_fdw_password` | - |
| `SERVICERADAR_COLD_TIER_PRIMARY_FDW_USERNAME` | 1/0 | config |  | `cold_tier.primary_fdw_username` | - |
| `SERVICERADAR_COLD_TIER_PRIMARY_HOST` | 1/0 | config |  | `cold_tier.primary_host` | - |
| `SERVICERADAR_COLD_TIER_PRIMARY_PORT` | 1/0 | config |  | `cold_tier.primary_port` | - |
| `SERVICERADAR_COLD_TIER_PRIMARY_VOLUME_BYTES` | 1/0 | config |  | `cold_tier.primary_volume_bytes` | - |
| `SERVICERADAR_COLD_TIER_S3_ACCESS_KEY_ID` | 1/0 | config |  | `cold_tier.s3_access_key_id` | - |
| `SERVICERADAR_COLD_TIER_S3_ENDPOINT` | 1/0 | config |  | `cold_tier.s3_endpoint` | - |
| `SERVICERADAR_COLD_TIER_S3_ENDPOINT_RUNTIME` | 1/0 | config |  | `cold_tier.s3_endpoint_runtime` | - |
| `SERVICERADAR_COLD_TIER_S3_REGION` | 1/0 | config |  | `cold_tier.s3_region` | - |
| `SERVICERADAR_COLD_TIER_S3_SECRET_ACCESS_KEY` | 1/0 | secret |  | secret: `cold_tier.s3_secret_access_key` | - |
| `SERVICERADAR_COLD_TIER_S3_URL_STYLE` | 1/0 | config |  | `cold_tier.s3_url_style` | - |
| `SERVICERADAR_COLD_TIER_S3_USE_SSL` | 1/0 | config |  | `cold_tier.s3_use_ssl` | - |
| `SERVICERADAR_COLD_WINDOW_EVENTS_DAYS` | 1/0 | config |  | `cold_tier.window_events_days` | - |
| `SERVICERADAR_COLD_WINDOW_FLOWS_DAYS` | 1/0 | config |  | `cold_tier.window_flows_days` | - |
| `SERVICERADAR_COLD_WINDOW_LOGS_DAYS` | 1/0 | config |  | `cold_tier.window_logs_days` | - |
| `SERVICERADAR_COLD_WINDOW_OTEL_METRICS_DAYS` | 1/0 | config |  | `cold_tier.window_otel_metrics_days` | - |
| `SERVICERADAR_COLD_WINDOW_OTEL_METRIC_POINTS_DAYS` | 1/0 | config |  | `cold_tier.window_otel_metric_points_days` | - |
| `SERVICERADAR_COLD_WINDOW_TIMESERIES_DAYS` | 1/0 | config |  | `cold_tier.window_timeseries_days` | - |
| `SERVICERADAR_COLD_WINDOW_TRACES_DAYS` | 1/0 | config |  | `cold_tier.window_traces_days` | - |

### 6.13 `testing` -- 15 names, 0 secrets, 19 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `CURRENT_AGENT_COUNT` | 1/0 | config |  | `testing.current_agent_count` | - |
| `DURABLE_CONSUMER_COUNT` | 1/0 | config |  | `testing.durable_consumer_count` | - |
| `MIX_TEST_PARTITION` | 2/0 | config |  | `testing.partition` | - |
| `OBSERVED_METRIC_MESSAGES_PER_SECOND` | 1/0 | config |  | `testing.observed_metric_messages_per_second` | - |
| `PROPERTY_MAX_RUNS` | 1/0 | config |  | `testing.property_max_runs` | - |
| `SERVICERADAR_ALLOW_DB_FREE_TESTS` | 2/0 | config |  | `testing.allow_db_free_tests` | - |
| `SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE` | 1/0 | config |  | `testing.large_ingestion_chunk_size` | scripts |
| `SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT` | 1/0 | config |  | `testing.large_ingestion_device_count` | scripts |
| `SERVICERADAR_ONLY_INTEGRATION` | 2/0 | config |  | `testing.only_integration` | ci-legacy |
| `SERVICERADAR_REPO_ROOT` | 1/0 | config |  | `testing.repo_root` | ci-legacy |
| `SERVICERADAR_REQUIRE_DB_TESTS` | 2/0 | config |  | `testing.require_db_tests` | - |
| `SERVICERADAR_SKIP_NIF_COMPILATION` | 1/0 | config |  | `testing.skip_nif_compilation` | - |
| `SERVICERADAR_TEST_DB_SHARD` | 1/0 | config |  | `testing.db_shard` | - |
| `SERVICERADAR_TEST_SLOWEST` | 1/0 | config |  | `testing.slowest` | bazel |
| `TARGET_AGENT_COUNT` | 1/0 | config |  | `testing.target_agent_count` | - |

### 6.14 `mail` -- 14 names, 1 secrets, 17 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `SERVICERADAR_MAILER_ADAPTER` | 1/1 | config |  | `mail.adapter` | helm |
| `SERVICERADAR_MAIL_FROM_EMAIL` | 1/0 | config |  | `mail.from_email` | helm |
| `SERVICERADAR_MAIL_FROM_NAME` | 1/0 | config |  | `mail.from_name` | helm |
| `SERVICERADAR_NOTIFICATION_ACTION_BASE_URL` | 2/0 | config |  | `mail.action_base_url` | helm |
| `SERVICERADAR_NOTIFICATION_PLATFORM_AGENT_ID` | 2/0 | config |  | `mail.platform_agent_id` | helm |
| `SERVICERADAR_NOTIFICATION_PLATFORM_AGENT_PARTITION` | 2/0 | config |  | `mail.platform_agent_partition` | helm |
| `SMTP_RELAY_AUTH` | 1/0 | config |  | `mail.relay_auth` | helm |
| `SMTP_RELAY_HOST` | 1/2 | config |  | `mail.relay_host` | helm |
| `SMTP_RELAY_HOSTNAME` | 1/0 | config |  | `mail.relay_hostname` | helm |
| `SMTP_RELAY_PASSWORD` | 1/1 | secret |  | secret: `mail.relay_password` | helm |
| `SMTP_RELAY_PORT` | 1/1 | config |  | `mail.relay_port` | helm |
| `SMTP_RELAY_SSL` | 1/0 | config |  | `mail.relay_ssl` | helm |
| `SMTP_RELAY_TLS` | 1/0 | config |  | `mail.relay_tls` | helm |
| `SMTP_RELAY_USERNAME` | 1/1 | config |  | `mail.relay_username` | helm |

### 6.15 `secrets_infra` -- 4 names, 4 secrets, 10 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `CLOAK_KEY` | 3/0 | secret |  | secret: `secrets_infra.cloak_key` | helm |
| `CLOAK_KEY_FILE` | 3/0 | secret | `CLOAK_KEY` | secret: `secrets_infra.cloak_key` | - |
| `OPENBAO_TOKEN` | 2/0 | secret |  | secret: `secrets_infra.openbao_token` | helm |
| `VAULT_TOKEN` | 2/0 | secret |  | secret: `secrets_infra.vault_token` | scripts |

### 6.16 `platform` -- 6 names, 0 secrets, 9 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `CI` | 1/0 | platform |  | (stays an env read) | - |
| `MIX_ENV` | 1/0 | platform |  | (stays an env read) | ci-legacy,scripts |
| `RELEASE_COOKIE` | 1/0 | platform |  | (stays an env read) | helm |
| `RUSTLER_TEMP_DIR` | 2/0 | platform | `RUSTLER_TMPDIR` | (stays an env read) | - |
| `RUSTLER_TMPDIR` | 3/0 | platform |  | (stays an env read) | - |
| `TEST_TMPDIR` | 1/0 | platform |  | (stays an env read) | - |

### 6.17 `control_plane` -- 6 names, 3 secrets, 6 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `CONTROL_PLANE_JWT_AUDIENCE` | 1/0 | config |  | `control_plane.jwt_audience` | - |
| `CONTROL_PLANE_JWT_ISSUER` | 1/0 | config |  | `control_plane.jwt_issuer` | - |
| `CONTROL_PLANE_PUBLIC_KEY` | 1/0 | material |  | secret: `control_plane.public_key` | - |
| `CONTROL_PLANE_PUBLIC_KEY_FILE` | 1/0 | material | `CONTROL_PLANE_PUBLIC_KEY` | secret: `control_plane.public_key` | - |
| `SERVICERADAR_CONTROL_PLANE_RUNTIME_PORT` | 1/0 | config |  | `control_plane.runtime_port` | helm |
| `SERVICERADAR_CONTROL_PLANE_RUNTIME_TOKEN` | 1/0 | secret |  | secret: `control_plane.runtime_token` | helm |

### 6.18 `srql` -- 1 names, 0 secrets, 2 read sites

| variable | R/W | kind | alias of | destination | set by |
|---|---|---|---|---|---|
| `SRQL_INTEGRATION` | 2/0 | config |  | `srql.integration` | - |

## 7. Migration plan

The goal is **zero environment reads in Elixir**, with `platform` (six names) as the only
allowlist. What follows is ordered so that every step is separately verifiable and no step
leaves a deployment in a state where a value is set but ignored.

### 7.0 Two things must happen before any conversion

**(a) Eliminate the 91 computed reads.** `System.get_env(var)` cannot be found by any gate,
so while they exist the exit criterion cannot be enforced and its green is meaningless. They
sit in 40 files; three quarters of them are inside the wrapper helpers themselves, so
converting a wrapper converts its whole call set at once:

| file | computed reads |
|---|---|
| [elixir/serviceradar_core/config/runtime.exs](elixir/serviceradar_core/config/runtime.exs) | 11 |
| [elixir/web-ng/config/runtime.exs](elixir/web-ng/config/runtime.exs) | 11 |
| [elixir/serviceradar_core_elx/config/runtime.exs](elixir/serviceradar_core_elx/config/runtime.exs) | 7 |
| [elixir/serviceradar_core/lib/serviceradar/event_writer/config.ex](elixir/serviceradar_core/lib/serviceradar/event_writer/config.ex) | 5 |
| [elixir/serviceradar_agent_gateway/config/runtime.exs](elixir/serviceradar_agent_gateway/config/runtime.exs) | 3 |

**(b) Land the gate before the conversions, failing.** A Bazel test that parses every
`elixir/**/*.ex{,s}` for all five read forms and fails on any name outside the platform
allowlist. Add it with the allowlist seeded to today's 670 names, then delete names from
the allowlist as each partition lands. The number in that allowlist is the migration's
progress bar, it is reviewable in a diff, and it cannot silently go up.

A gate written after the work measures nothing: every conversion would be self-certified.

### 7.1 Collapse aliases first, inside the current design

63 pairs proven in section 4.1 mean **676 names carry 622 distinct values**. Deleting an
alias is a pure Elixir edit with no schema, no Helm and no manager involved: pick the
canonical spelling, delete the fallback arm, delete the matching Helm `env:` entry if the
losing spelling has one.

Do this first for two reasons. It shrinks every later step by the same 54 names. And it is
the only class of change here that is provably behaviour-preserving -- the losing arm was
already unreachable whenever the winning one was set.

### 7.2 Decide the 350 never-set names

350 of 676 names are read with a default and set by nothing in this repository, and section
3.1 measured what that means: six raise, the other 340 change behaviour and say nothing.
Each is one of two things, and the decision is per name, not per partition:

- **A real knob that operators are expected to set by hand.** It gets a schema field with
  the default it already has, and the default moves from Elixir into the committed instance
  where it is reviewable.
- **A knob nobody uses.** Delete the read. 279 of the 350 are read exactly once and set
  nowhere -- for those the burden of proof is on keeping them.

Either outcome ends the silence: a field the schema declares is a field the validator can
require, so an absent value becomes a boot-time error naming it rather than a `nil` threaded
into a NATS connection or a cold-tier config map.

Doing this before the schema work is what stops the schema from being a transcription of
every accident in the codebase. A schema with 622 fields is not a configuration system; it
is the same problem in a different file format.

### 7.3 One partition at a time

For each partition in the order given in 5.3 (`database`, `identity`, `messaging` first):

1. **Schema.** Add `config/proto/<partition>.proto` with the fields from section 6, every
   one `optional`, every enum reserving 0. Credentials do not appear -- they get logical
   names in the partition's `secrets` module instead.
2. **Instances.** Add `config/environments/<env>/<partition>.textproto` for all five
   environments. Values come from the Helm templates and the current Elixir defaults; where
   those two disagree, the Helm value is the truth for `saas`/`demo`/`onprem` and the Elixir
   default is the truth for `localhost`. Record any disagreement in the commit message --
   a disagreement is a live misconfiguration, not a merge conflict.
3. **Managers.** One target per language per partition, embedding only that partition's
   `binpb`. A consumer depends on `//config/manager_config/<lang>:<partition>` and on
   nothing else, which is the whole point of 5.
4. **Rewrite the reads.** In the module that needs the value, not in `runtime.exs`.
   `runtime.exs` may read a partition only for values Phoenix and Ecto genuinely require at
   boot.
5. **Delete the Helm `env:` entries** in the same commit. A converted read plus a surviving
   `env:` entry is a manifest that documents a control that no longer controls anything.
6. **Shrink the gate's allowlist** by exactly the names this partition covers. If the
   allowlist does not shrink, nothing was migrated.

### 7.4 Secrets

67 credential names collapse to **43 distinct credentials**, of which four already have
logical names (`config/manager_config/rust/src/secrets.rs`:
`database.password`, `database.ca_cert`, `database.client_cert`, `database.client_key`).

Two shapes disappear entirely rather than being ported:

- **The `_FILE` duality.** Every secret is read as value-or-file with the choice resolved at
  the call site. The provider abstraction is exactly this decision, made once. `NAME` and
  `NAME_FILE` both become one logical name.
- **`*_CERT_DIR`.** `SPIFFE_CERT_DIR`, `CNPG_CERT_DIR`, `DATASVC_CERT_DIR`,
  `GATEWAY_CERT_DIR`, `OTEL_CERT_DIR`, `NATS_TEST_CERT_DIR` all name a directory and then
  assume filenames inside it. Content-resolved secrets remove both the directory and the
  filename convention -- the caller asks for `identity.client_cert` and receives PEM.

`material` in section 6 is credential material that is not confidential: CA bundles, public
verification keys. It resolves through SecretManager anyway, because the schema's own rule
says certificate material is not configuration -- the same reason `database.ca_cert` is a
secret name today despite a CA certificate being public.

### 7.5 What phase 7 as currently written actually covers

Phase 7 as scoped in `tasks.md` converts the reads the schema already models: **58 names,
127 read sites**. That is 12% of the surface. It is worth doing and it is not zero
environment reads.

The remaining 545 names need schema fields that do not exist yet. That work is section 7.2
plus section 7.3 repeated seventeen times, and it should be sized and scheduled explicitly
rather than inherited as the tail of a phase whose exit criterion it does not appear in.

### 7.6 Ordering against task 8

Task 8 (manifests) is not a follow-up: it is the second half of each step in 7.3. 301 names
are supplied by Helm -- four templates account for almost all of them -- and a partition is
not migrated until its `env:` block
is gone. Sequencing task 8 after all of phase 7 guarantees a window in which every converted
value is still being set by Helm and silently ignored.
