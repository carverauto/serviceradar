# Integration database fixture: environment and TLS contract

This crate owns the lifecycle of the `serviceradar_core` integration database — create the
template, clone a per-run database, tear it down, sweep what earlier runs leaked. It reaches
CNPG entirely through environment variables, and **those variables are supplied differently by
each of the three environments the suite runs in**.

This document exists because the CA is currently delivered as PEM *content* in an environment
variable, and that is expected to be replaced. Anything that swaps the delivery mechanism has
to satisfy every row of the tables below, or it will break one environment while leaving the
other two green — which is exactly how the failures listed at the end reached `staging`.

## The three environments

| | local dev | Forgejo Actions | BuildBuddy Workflow |
|---|---|---|---|
| fixture | your own Postgres (docker) | shared `srql-fixtures` CNPG | shared `srql-fixtures` CNPG |
| setup | you export by hand | `scripts/ci/configure-srql-fixture.sh` | `//:buildbuddy_setup_fixture_env` |
| CA delivered as | usually nothing (TLS off) | **file path AND PEM content** | **PEM content only** |
| where tests execute | your machine | the runner | a remote executor |

The last two rows are the whole problem. Forgejo sets both forms of the CA, so a consumer that
reads only the file path works there. BuildBuddy sets only the content form, because a path
names a file on the machine that launched the build and a remote executor has no such file.
**A path-only consumer is green on Forgejo and broken on BuildBuddy.**

## What each setup exports

`//:buildbuddy_setup_fixture_env` (`buildbuddy_setup_fixture_env.sh`) — four names:

| variable | form | notes |
|---|---|---|
| `SRQL_TEST_DATABASE_URL` | DSN | `?sslmode=` only on the kubectl path — see below |
| `SRQL_TEST_ADMIN_URL` | DSN | same |
| `SRQL_TEST_DATABASE_CA_CERT` | **PEM content** | not a path |
| `SRQL_FIXTURE_SSLMODE` | input knob | kubectl path only; default `verify-full` |

The script has two credential paths and they do **not** produce the same DSN:

- **Path 1, kubectl** — builds the DSN itself and appends `?sslmode=${SRQL_FIXTURE_SSLMODE}`,
  default `verify-full`.
- **Path 2, pre-set BuildBuddy secrets** — uses `SRQL_TEST_DATABASE_URL` /
  `SRQL_TEST_ADMIN_URL` **verbatim**. If the stored secret has no `?sslmode=`, nothing adds one.

BuildBuddy is on Path 2 today, so **its DSNs carry no `sslmode` at all**. Every "what happens
when nothing names a mode" rule below is therefore the live path, not a corner case. The run
log says which path was used: `Fixture credentials from <source>`.

`scripts/ci/configure-srql-fixture.sh` — the same DSNs plus **both** CA forms and the client
cert/key, as files on the runner:

```
SRQL_TEST_DATABASE_CA_CERT          (content)
SRQL_TEST_DATABASE_CA_CERT_FILE     (path)     SERVICERADAR_TEST_DATABASE_CA_CERT_FILE
SRQL_TEST_DATABASE_CERT / _KEY      (paths)    SERVICERADAR_TEST_DATABASE_CERT / _KEY
CNPG_CA_FILE  PGSSLROOTCERT  PGSSLCERT  PGSSLKEY
```

## Two gates, not one

A variable reaches a Bazel test action only if it is **both** exported by the setup above
**and** named in `//.bazelrc` as `test --test_env=<NAME>`. Miss either and it is simply absent;
nothing warns.

Currently forwarded, of the TLS family:

| variable | forwarded? |
|---|---|
| `SRQL_TEST_DATABASE_URL`, `SRQL_TEST_ADMIN_URL` | yes |
| `SRQL_TEST_DATABASE_CA_CERT` (content) | yes |
| `PGSSLROOTCERT`, `PGSSLSERVERNAME` | yes |
| `SERVICERADAR_TEST_DATABASE_CA_CERT` (content) | **no** |
| `*_CA_CERT_FILE`, `CNPG_CA_FILE` | **no** |
| `SRQL_TEST_DATABASE_CERT` / `_KEY` | **no** |

So inside a Bazel test the `SERVICERADAR_*` spelling of the CA **content** is dead — only the
`SRQL_*` spelling arrives. Code that accepts both is fine; code that reads only the
`SERVICERADAR_*` one silently gets nothing.

## `sslmode` is not portable across the three consumers

Do not assume a value that works in one place parses in another.

**This crate cannot accept `verify-full` or `verify-ca`.** It hands the DSN to
tokio-postgres, whose `sslmode` accepts only `disable|prefer|require`; anything else aborts
before connecting:

```
Caused by: 0: invalid connection string
           1: invalid value for option `sslmode`
```

That is a hard constraint on whatever replaces the current mechanism: **putting `verify-full`
in `SRQL_TEST_DATABASE_URL` breaks `prepare_template`, `provision_db`, `teardown_db` and
`sweep_stale_dbs` outright.** It is also why the kubectl path's `verify-full` default has never
been exercised on BuildBuddy — Path 2 supplies no `sslmode`, and the crate only survives
because of the next point.

**This crate does not depend on `sslmode`.** It connects through `srql::db::PgRustlsConnect`
using the PEM content directly, so it is always TLS regardless of what the DSN says. It was
green throughout every TLS failure listed at the end, which is precisely why those failures
looked like Elixir problems rather than fixture problems.

**The Elixir consumers do depend on it**, and both must treat "nothing named a mode" as
"a CA was supplied, so TLS was intended". Defaulting to plaintext there is what produced two of
the four failures below.

## Who reads what

This crate (`src/lib.rs`): `SRQL_TEST_DATABASE_URL`, `SRQL_TEST_ADMIN_URL`,
`SERVICERADAR_TEST_ADMIN_URL`, `SRQL_TEST_DATABASE_CA_CERT`, `SERVICERADAR_TEST_DATABASE_OWNER`,
`PGSSLROOTCERT`, `PGSSLSERVERNAME`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`.

`elixir/serviceradar_core/config/test.exs` resolves the Repo. Order that matters:

1. `sslmode` comes from the DSN query first, then `*_DATABASE_SSLMODE`, then `CNPG_SSL_MODE`.
2. TLS is enabled if that mode is `require|verify-ca|verify-full`, **or** a CA is present in
   either form. The second half is load-bearing remotely: no path variable resolves on an
   executor, so without it a DSN lacking `sslmode=` connects in plaintext.
3. `:cacerts` (decoded PEM content) is preferred over `:cacertfile` (a path). Never both —
   `:ssl` rejects the combination.

`database_bootstrap_integration_test.exs` does **not** use the Repo. It builds its own
`Postgrex.start_link` options and spawns a subprocess, so it needs the same resolution
duplicated. It also passes the CA to that subprocess explicitly.

## Running it locally

The lifecycle is an ordered sequence of Bazel invocations, not a script:

```
bazel test -c opt --//build:enable_integration_tests //rust/integration-db:sweep_stale_dbs
bazel run  -c opt --//build:enable_integration_tests //rust/integration-db:prepare_template
bazel test -c opt --//build:enable_integration_tests //elixir/serviceradar_core:migrate_template
bazel test -c opt --//build:enable_integration_tests //rust/integration-db:provision_db
   ... the suite ...
bazel test -c opt --//build:enable_integration_tests //rust/integration-db:teardown_db
```

`provision_db` refuses to clone a template that is behind the migrations on disk, which is why
`migrate_template` sits between them. Do not reorder.

Against a local docker Postgres with TLS off:

```
export SRQL_TEST_ADMIN_URL='postgres://<admin>:<pw>@127.0.0.1:5432/postgres?sslmode=disable'
export SRQL_TEST_DATABASE_URL='postgres://<app>:<pw>@127.0.0.1:5432/serviceradar_test?sslmode=disable'
```

The image must carry all of `REQUIRED_EXTENSIONS` (`pgcrypto pg_trgm citext timescaledb age
postgis vector`) with `age` and `timescaledb` in `shared_preload_libraries`.
`registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.4.0-sr4` does; it is operator-managed,
so it has no entrypoint and its binaries are not on `PATH` — you have to `initdb` and start
`postgres` yourself.

The owner of the template and every clone is taken from the **user in
`SRQL_TEST_DATABASE_URL`**, never hardcoded, because the suite connects as that role and a
database owned by anyone else fails on its first DDL.

### Reproducing the remote TLS path locally

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

Then run with the BuildBuddy shape — content CA, **no** `sslmode`, **no** path variables:

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

1. If you start putting `sslmode` in the DSNs, it must be one of `disable|prefer|require` —
   `verify-ca`/`verify-full` abort this crate before it connects.
2. The CA reaches a **remote executor** — no filesystem path on the launching machine.
3. Every new variable is added to `//.bazelrc` `test --test_env=`. Exported is not enough.
4. All three consumers are updated: this crate, `config/test.exs`, and
   `database_bootstrap_integration_test.exs` (including the env it hands its subprocess).
   The two Elixir ones each decide independently whether TLS is on; they have diverged before.
5. Exercised against a **TLS-only** fixture, per the recipe above. A plaintext fixture passes
   through every bug listed here.
6. Verified on BuildBuddy, not only Forgejo. Forgejo sets both CA forms and both fixture paths
   set `CNPG_SSL_MODE`, so it stays green through a change that breaks remote execution.
