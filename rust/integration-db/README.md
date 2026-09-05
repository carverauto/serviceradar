# Integration database fixture: environment and TLS contract

## Keyed generation lifecycle (opt-in)

The legacy `prepare_template` text interface and provisioning targets remain available
during rollout. The new guarded targets are `prepare_generation`, `provision_generation`,
`provision_generation_large_ingestion`, `release_generation`, and `cleanup_generations`.
They consume the declared `build/schema_template/manifest.json` and `policy.json`;
there are no ambient generation or capacity overrides. Preparation emits JSON with
`status` (`needs_migration` or `ready`), `digest`, `database`, and `builder_token`.

The SQL contract is `registry.sql`. All locks and registry queries use `postgres`.
Generation session locks use `(1397904460, signed_int32(digest[0:8]))`; registry
initialization/capacity uses `(1397904461, 0)`. Acquire generation before capacity
when both are needed. Rust prepares or recreates a private `building` database named
`sr_tpl_` plus the first 48 digest characters. The Elixir builder rereads and advances
the fencing token under its generation lock, holds that session through full replay,
ledger/extension verification, Repo shutdown, connection disabling, and publication.
Ready generations are immutable. PostgreSQL major and required extension versions
must match the registry on reuse. Full replay is mandatory until baseline provenance
has been independently established.

Both building and ready preparations acquire a lease for the declared run database.
Cloning rechecks readiness and renews that lease while holding the generation lock.
Building recovery may replace a failed candidate despite old leases, but requires
ownership and no connected backends; builders must always reread the token. Leases
prevent cleanup during the gap between preparation and migration. Teardown drops
disposable clones; `release_generation` releases only its run's lease. Cleanup never
forces a drop, requires a registered exact identity, expired retention, no live lease,
no builder lock and no connections, and rechecks the database catalog after dropping.
At capacity, preparation fails with guidance to finish/recover builders or run cleanup.

`generation_lifecycle_test` is an unexecuted-until-qualified, guarded in-cluster test.
It uses invented schema inputs and separate PostgreSQL sessions to check schema and
ledger artifacts, reuse, recovery, fencing, capacity, lease renewal and cleanup locks.
It cleans only its own generation identities. This does not qualify application full
replay, independent OS-process orchestration, or the cold-baseline lock budget.
Before workflow activation, deploy `sr_tpl_` exclusions to every ordinary reaper and
complete those separate qualification gates. Merely compiling this target does not
execute database operations.

This crate owns the lifecycle of the `serviceradar_core` integration database — create the
template, clone a per-run database, tear it down, sweep what earlier runs leaked. It reaches
CNPG entirely through environment variables, and **those variables are supplied differently by
each of the three environments the suite runs in**.

This document exists because the CA is delivered as PEM *content* in an environment variable
after being fetched from a live source (the cert-manager Secret or
`https://srql-fixture-ca.carverauto.dev/ca.crt`). Anything that swaps the delivery
mechanism has to satisfy every row of the tables below, or it will break one environment
while leaving the other two green — which is exactly how earlier failures reached `staging`.

## The three environments

| | local dev | GitHub ARC (carverauto) | BuildBuddy Workflow |
|---|---|---|---|
| fixture | Docker Postgres or shared `srql-fixtures` NodePort | shared `srql-fixtures` CNPG | shared `srql-fixtures` CNPG |
| setup | `.agents/skills/srql-fixtures-db-tests` + credential target | `scripts/ci/configure-srql-fixture.sh` | `//:buildbuddy_setup_fixture_env` |
| CA delivered as | none for Docker; **PEM content** for NodePort | **file path AND PEM content** from LAN HTTPS | **PEM content only** |
| where tests execute | your machine | `arc-runner-set` pod | the self-hosted workflow runner |

The content form keeps the credential contract independent of a runner-local path and remains
safe if execution ownership changes. The live workflows keep database-facing TestRunner actions
on their fixture-reachable runners while eligible compilation remains remote and cached.

## What each setup exports

`//:buildbuddy_setup_fixture_env` (`buildbuddy_setup_fixture_env.sh`) writes five names:

| variable | form | notes |
|---|---|---|
| `SRQL_TEST_DATABASE_URL` | DSN | always normalized to the configured `sslmode` |
| `SRQL_TEST_ADMIN_URL` | DSN | same |
| `SRQL_TEST_DATABASE_CA_CERT` | **PEM content** | not a path |
| `SRQL_TEST_DATABASE_SERVER_NAME` | DNS name | Postgrex certificate verification |
| `PGSSLSERVERNAME` | DNS name | Rust certificate verification |

`SRQL_FIXTURE_SSLMODE` is an input knob shared by both DSN paths and defaults to
`verify-full`:

- **DSNs, kubectl** — builds the DSN itself and appends `?sslmode=${SRQL_FIXTURE_SSLMODE}`,
  default `verify-full`.
- **DSNs, pre-set workflow secrets** — preserves the credentials/endpoint but adds or replaces
  `sslmode` with the same configured value.
- **CA** — never a stored secret. kubectl reads `srql-fixture-server-ca` when RBAC exists,
  otherwise GET `SRQL_FIXTURE_CA_URL` (default
  `https://srql-fixture-ca.carverauto.dev/ca.crt`).
  That URL is LAN HTTPS (Let's Encrypt on lan-shared-gateway), not a public VIP.

The run log says which credential source was used without printing userinfo:
`Fixture credentials from <source>`.

`scripts/ci/configure-srql-fixture.sh` — the same DSNs plus **both** CA forms and the client
cert/key, as files on the runner:

```
SRQL_TEST_DATABASE_CA_CERT          (content)
SRQL_TEST_DATABASE_CA_CERT_FILE     (path)     SERVICERADAR_TEST_DATABASE_CA_CERT_FILE
SRQL_TEST_DATABASE_CERT / _KEY      (paths)    SERVICERADAR_TEST_DATABASE_CERT / _KEY
CNPG_CA_FILE  PGSSLROOTCERT  PGSSLCERT  PGSSLKEY
```

## Two gates, not one

A variable reaches a Bazel test action only if it is **both** exported by the setup above and the
invocation selects `--config=database_env`, whose `test:database_env --test_env=<NAME>` entries are
the forwarding boundary. Miss either and it is simply absent; nothing warns. Keeping that profile
opt-in prevents DSNs and TLS/NATS key material from entering generic remote unit-test metadata.

Currently forwarded, of the TLS family:

| variable | forwarded? |
|---|---|
| `SRQL_TEST_DATABASE_URL`, `SRQL_TEST_ADMIN_URL` | yes |
| `SRQL_TEST_DATABASE_CA_CERT` (content) | yes |
| `PGSSLROOTCERT`, `PGSSLSERVERNAME`, `SRQL_TEST_DATABASE_SERVER_NAME` | yes |
| `SERVICERADAR_TEST_DATABASE_CA_CERT` (content) | yes |
| `*_CA_CERT_FILE`, `CNPG_CA_FILE` | yes |
| `SRQL_TEST_DATABASE_CERT` / `_KEY` | yes |

The final `SERVICERADAR_TEST_DATABASE_URL` and `SERVICERADAR_TEST_ADMIN_URL` overrides are
intentionally not forwarded. Inheriting either would suppress the per-shard database URL derived
from the canonical `SRQL_TEST_*` base.

## `sslmode` is not portable across the three consumers

Do not assume a value that works in one place parses in another.

`tokio-postgres` accepts only `disable|prefer|require`, while libpq and Postgrex also accept
`verify-ca` and `verify-full`. This crate therefore normalizes those two verified modes to
`require` only while parsing its private `tokio-postgres::Config`. It does not rewrite the
shared DSN. The Rust connection still uses `srql::db::PgRustlsConnect` with the supplied fixture
CA, and `PGSSLSERVERNAME` supplies the certificate DNS name when the DSN addresses a NodePort IP.
The Elixir consumers see the original `verify-ca`/`verify-full` value and enable `verify_peer`.

Without that parser-boundary normalization, the kubectl setup path's `verify-full` default
aborts `provision_base`, `provision_db`, `teardown_db`, and `sweep_stale_dbs` before they can
connect. A pure Rust lifecycle regression covers both verified libpq modes.

**The Elixir consumers do depend on it**, and both must treat "nothing named a mode" as
"a CA was supplied, so TLS was intended". Defaulting to plaintext there is what produced two of
the four failures below.

## Who reads what

This crate (`src/lib.rs`): `SRQL_TEST_DATABASE_URL`, `SRQL_TEST_ADMIN_URL`,
`SERVICERADAR_TEST_ADMIN_URL`, `SRQL_TEST_DATABASE_CA_CERT`, `SERVICERADAR_TEST_DATABASE_OWNER`,
`PGSSLROOTCERT`, `PGSSLSERVERNAME`.

The per-run database name is NOT an environment variable. It is read from the declared input
`//build:run_id_file` (staged at `build/run_id_file.txt` in runfiles), written from
`--//build:run_id`. //elixir/serviceradar_core reads the same file, so there is one producer of
the format rather than two implementations kept in step by hand.

`elixir/serviceradar_core/config/test.exs` resolves the Repo. Order that matters:

1. `sslmode` comes from the DSN query first, then `*_DATABASE_SSLMODE`, then `CNPG_SSL_MODE`.
2. TLS is enabled if that mode is `require|verify-ca|verify-full`, **or** a CA is present in
   either form. The second half keeps local and Bazel-sandbox callers safe when an
   unnormalized DSN lacks `sslmode=` but supplies a CA.
3. `:cacerts` (decoded PEM content) is preferred over `:cacertfile` (a path). Never both —
   `:ssl` rejects the combination.

`database_bootstrap_integration_test.exs` does **not** use the Repo. It builds its own
`Postgrex.start_link` options and spawns a subprocess, so it needs the same resolution
duplicated. It also passes the CA to that subprocess explicitly.

## Running it locally

Use [the SRQL fixture skill](../../.agents/skills/srql-fixtures-db-tests/SKILL.md) for the
canonical runnable recipe. The lifecycle is an ordered sequence of Bazel invocations, not a
wrapper script:

`sweep -> provision base -> conditional migrate run -> provision lanes -> suite -> teardown`

Note what is NOT in that sequence: `prepare_template` and `migrate_template`. They write the
shared `sr_core_template`, which only the trunk lifecycle may do, and they refuse without
`--//build:template_authority=true` -- so a workstation cannot ratchet the fixture CI shares,
which it previously could. `provision_base` seeds this run's own `sr_core_test_<run>` from the
template and `migrate_run` applies your migrations there.

Every target must receive `--//build:enable_integration_tests`. Database tests clear the manual
test filter, use `--strategy=TestRunner=local`, and disable test-result caching. `provision_base`
clears the manual build filter and reports migration status on stdout; the caller matches
`migration(s) pending`. Keep the base fixture DSNs in `SRQL_TEST_*`, use one numeric run
ID/attempt for the whole sequence, and pair `provision_db_sN` with `integration_tests_sN` for a
focused run. Always invoke `teardown_db` after provisioning, including after a red shard.
`provision_db` refuses to clone a base that is behind the migrations on disk, so do not reorder
the sequence.

Against a local docker Postgres with TLS off:

```
export SRQL_TEST_ADMIN_URL='postgres://<admin>:<pw>@127.0.0.1:5432/postgres?sslmode=disable'
export SRQL_TEST_DATABASE_URL='postgres://<app>:<pw>@127.0.0.1:5432/serviceradar_test?sslmode=disable'
```

For that Docker variant, reuse the skill recipe from `run_entropy` onward with the two preset URLs
above. Omit its Kubernetes host/TLS exports and `buildbuddy_setup_fixture_env`/source lines; those
deliberately select the shared CNPG fixture and require its CA.

The image must carry all of `REQUIRED_EXTENSIONS` (`pgcrypto pg_trgm citext timescaledb age
postgis vector`) with `age` and `timescaledb` in `shared_preload_libraries`.
`registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.4.0-sr4` does; it is operator-managed,
so it has no entrypoint and its binaries are not on `PATH` — you have to `initdb` and start
`postgres` yourself.

The owner of the template and every clone is taken from the **user in
`SRQL_TEST_DATABASE_URL`**, never hardcoded, because the suite connects as that role and a
database owned by anyone else fails on its first DDL.

### Reproducing the CA-content fallback locally

A plaintext fixture cannot exercise any of this — every TLS bug listed below is invisible with
`sslmode=disable`. To get a fixture that behaves like CI, give the container a certificate and
make `pg_hba` refuse plaintext:

```
openssl req -new -x509 -days 2 -nodes -keyout ca.key -out ca.crt -subj "/CN=test-ca"
openssl req -new    -nodes -keyout server.key -out server.csr -subj "/CN=localhost"
printf 'subjectAltName = DNS:localhost, IP:127.0.0.1\n' > san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out server.crt -days 2 -extfile san.ext
```

In `PGDATA`: copy `server.crt`/`server.key` (key mode 600), set `ssl = on` plus
`ssl_cert_file`/`ssl_key_file`, and **replace** `pg_hba.conf` rather than appending to it —
first match wins, and initdb's default `host all all 127.0.0.1/32` line will otherwise accept
plaintext before your rule is reached:

```
local   all all      trust
hostssl all all 0.0.0.0/0 scram-sha-256
hostssl all all ::0/0     scram-sha-256
```

The checked-in BuildBuddy and Forgejo setup now normalizes both DSNs to `verify-full` and supplies
the certificate server name. To reproduce the older, unnormalized fallback regression instead,
use a content CA with **no** `sslmode` and **no** path variables:

```
unset PGSSLROOTCERT CNPG_CA_FILE CNPG_SSL_MODE \
      SRQL_TEST_DATABASE_CA_CERT_FILE SERVICERADAR_TEST_DATABASE_CA_CERT_FILE
export SRQL_TEST_ADMIN_URL='postgres://<admin>:<pw>@localhost:5432/postgres'
export SRQL_TEST_DATABASE_URL='postgres://<app>:<pw>@localhost:5432/serviceradar_test'
export SRQL_TEST_DATABASE_CA_CERT="$(cat ca.crt)"
```

Connect by the name in the certificate (`localhost`), not by IP — `verify-full` checks the
hostname against the SAN. Sanity-check the fixture before trusting a result: plaintext must be
refused with `no encryption`, and `sslmode=verify-full&sslrootcert=ca.crt` must succeed.

## AGE graph ownership

`ag_catalog.create_graph` creates a schema per graph, owned by the role that called it — the
admin. `own_graph_schemas` then transfers each graph schema, and the tables and sequences AGE
put in it, to the application role.

Ownership, not `GRANT`: migration `20260622210000` does `CREATE INDEX` on a label table, and
index creation requires being the table owner. No combination of `GRANT` confers that.

Sequences `OWNED BY` a column are skipped — they follow their table, and `ALTER SEQUENCE ...
OWNER TO` on one fails outright (`cannot change owner of sequence "_ag_label_edge_id_seq"`).

## Failures this contract has already produced

Each was green in one environment and broken in another, which is the failure mode this
document is meant to prevent.

- `pg_hba.conf rejects connection ... no encryption` — the Repo had a PEM CA but no `sslmode=`
  in the DSN, and TLS was only enabled by the *path* forms. Remotely those never resolve.
- `permission denied for schema platform_graph` — graphs owned by the admin; the app role could
  not read them, let alone index them.
- `connection not available and request was dropped from queue after 4000ms` in
  `database_bootstrap_integration_test.exs` — that test does not use the Repo. It builds its
  own `Postgrex.start_link` options, and its `sslmode` resolution defaulted to `"disable"` when
  nothing named a mode, so it connected in plaintext to a fixture that refuses it. The real
  cause is one line further down the log:

  ```
  FATAL 28000 no pg_hba.conf entry for host "...", user "srql_hydra", ..., no encryption
  ```

  **Always read past the queue timeout.** Postgrex retries a rejected connect in the
  background, so the pool never becomes ready and the *first query* fails on the queue — the
  connect error is what tells you why. This shape means "TLS misconfigured", not "pool too
  small"; raising `pool_size` or `queue_target` will not help.

## If you replace the PEM-in-env mechanism

Check all of it:

1. If you add or change `sslmode`, preserve the parser-boundary normalization for libpq
   `verify-ca`/`verify-full`; do not rewrite the shared DSN or weaken the rustls verification
   path.
2. The CA contract does not depend on a runner-local filesystem path and remains safe if action
   placement changes.
3. Every new variable is added to the opt-in `//.bazelrc` `test:database_env --test_env=` profile.
   Exported is not enough, and global forwarding is a credential leak.
4. All three consumers are updated: this crate, `config/test.exs`, and
   `database_bootstrap_integration_test.exs` (including the env it hands its subprocess).
   The two Elixir ones each decide independently whether TLS is on; they have diverged before.
5. Exercised against a **TLS-only** fixture, per the recipe above. A plaintext fixture passes
   through every bug listed here.
6. Verified on BuildBuddy, not only Forgejo. The two setup paths intentionally deliver different
   CA forms and have diverged before.
