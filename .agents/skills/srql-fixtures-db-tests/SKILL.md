---
name: srql-fixtures-db-tests
description: Run focused ServiceRadar Elixir database tests against a scratch database on the Kubernetes CNPG instance in the `srql-fixtures` namespace. The guarded Bazel integration lifecycle runs only in the in-cluster BuildBuddy workflow using typed ci configuration.
---

# SRQL Fixtures DB Tests

Use this skill for a focused Mix test against a separately created scratch database on the shared
CNPG cluster in the Kubernetes `srql-fixtures` namespace. The full async/serial
`serviceradar_core` guarded lifecycle is CI-only: it runs in the in-cluster BuildBuddy workflow
with typed `SERVICERADAR_ENV=ci` configuration.

## Guardrails

- Do not print database passwords or full URLs containing credentials.
- Use a scratch database named with a unique prefix, for example `codex_<topic>_<timestamp>_<pid>`.
- Verify the CNPG certificate. For a NodePort IP used by a focused scratch test, set the
  certificate's DNS name through `SRQL_TEST_DATABASE_SERVER_NAME` and use `sslmode=verify-full`
  with the fixture CA.
- Prefer the existing NodePort/LoadBalancer service over `kubectl port-forward` for the scratch
  database; port-forwarding to CNPG is flaky and should be fallback only.
- Keep the Ecto sandbox pool small for an individual scratch-DB test. The guarded async lane runs
  `max_cases=8` with `pool_size=12`; its four extra checkout slots are BEAM-internal headroom for
  test-supervised child processes, not workstation or deployment capacity.
- Only the in-cluster BuildBuddy workflow may run guarded lanes. It creates disposable
  `sr_core_test_<run-id>_<lane>` clones on `srql-fixtures` using typed ci configuration. Never
  point a guarded lifecycle at demo, production, or any non-disposable database.
- Do not invent a NodePort/config override for guarded lanes and do not forward fixture secrets
  to remote actions.
- Drop the scratch database when finished unless the user asks to keep it for inspection.

## Workstation NodePort Discovery For A Scratch Database

From the repo root:

```bash
kubectl get pods -n srql-fixtures -l cnpg.io/cluster=srql-fixture -L cnpg.io/instanceRole -o wide
kubectl get svc srql-fixture-rw-ext -n srql-fixtures -o wide
kubectl get nodes -o wide
kubectl get secret srql-test-admin-credentials -n srql-fixtures -o json | jq -r '.data | keys[]'
```

Use the `srql-fixture-rw-ext` service for write tests. It is currently exposed as NodePort `30818` and may also advertise an external LoadBalancer IP; verify routeability before choosing the host. Read admin credentials into shell variables without echoing the password:

```bash
ADMIN_USER=$(kubectl get secret srql-test-admin-credentials -n srql-fixtures -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl get secret srql-test-admin-credentials -n srql-fixtures -o jsonpath='{.data.password}' | base64 -d)
ADMIN_PASS_ENC=$(printf '%s' "$ADMIN_PASS" | jq -sRr @uri)
TLS_SERVER_NAME=srql-fixture-rw.srql-fixtures.svc.cluster.local
CA_FILE="${TMPDIR:-/tmp}/srql-fixture-ca-$$.crt"
umask 077
kubectl get secret srql-fixture-server-ca -n srql-fixtures -o jsonpath='{.data.ca\.crt}' | \
  base64 -d > "$CA_FILE"
```

Pick a reachable host/port. From the usual workstation, `192.168.10.31:30818` has been reachable while the advertised LoadBalancer IP may not be:

```bash
NODEPORT=$(kubectl get svc srql-fixture-rw-ext -n srql-fixtures -o jsonpath='{.spec.ports[0].nodePort}')

for host in 192.168.10.31 192.168.10.96 $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'); do
  if PGPASSWORD="$ADMIN_PASS" psql \
    "host=$TLS_SERVER_NAME hostaddr=$host port=$NODEPORT dbname=postgres user=$ADMIN_USER sslmode=verify-full sslrootcert=$CA_FILE connect_timeout=4" \
    -v ON_ERROR_STOP=1 -Atc 'select 1' >/dev/null 2>&1; then
    DB_HOST="$host"
    DB_PORT="$NODEPORT"
    break
  fi
done

test -n "${DB_HOST:-}" || { echo "no reachable srql-fixtures NodePort host"; exit 1; }
```

## Guarded Serviceradar Core Lanes: BuildBuddy Workflow Only

Do not run the full guarded lifecycle from a workstation or substitute the NodePort coordinates
above. The guarded Elixir lane and Rust lifecycle resolve their one legitimate endpoint from the
typed `SERVICERADAR_ENV=ci` instance; legacy `SRQL_TEST_*` endpoint coordinates are deliberately
ignored so provisioning and execution cannot diverge.

Use the in-cluster BuildBuddy workflow in `buildbuddy.yaml` for the complete sequence:

```text
private fixture setup -> sweep_stale_dbs -> cleanup_generations -> prepare_generation
  -> migrate_generation (only on needs_migration) -> prepare_generation (must be ready)
  -> provision_generation -> lane tests -> teardown_db -> release_generation
```

Every run clones its lanes from an immutable schema generation, `sr_tpl_<first 48 hex of the
digest>`, where the digest is `//build/schema_template:manifest`'s hash of the migrations,
baseline, helpers and construction inputs. A checkout with new migrations gets a new digest and
its own generation, which `//elixir/serviceradar_core:migrate_generation` builds by full replay;
a ready generation is never written again, so one branch's unmerged migrations can never become
the schema another branch clones. Generation count, concurrent builders, storage, retention and
lease length are bounded by `build/schema_template/policy.json`, and `cleanup_generations`
reclaims only idle, unleased, unconnected generations. See `docs/docs/ci-schema-templates.md`.

`sr_core_template` is a frozen rollback artifact: no workflow migrates it or clones from it.
Do not write it. `//elixir/serviceradar_core:migrate_template`,
`//rust/integration-db:prepare_template` and `//rust/integration-db:reset_template` still refuse
without `--//build:template_authority=true`, and the CI contract test fails if any active
workflow passes that flag -- never reach for it to get past a refusal. The accepted
retirement plan deletes those writers and the flag; after it lands there is no flag to pass
and no writer to refuse, and rolling back to the singleton lifecycle means reverting the
retirement code first.

That workflow owns `SERVICERADAR_ENV=ci`, the typed configuration inputs, the private secret
environment, capacity observer, run ID, and caller-owned cleanup. It keeps secret-bearing test
actions local to the workflow runner instead of forwarding secrets to remote actions. Do not
recreate those inputs from `SRQL_FIXTURE_HOST`, NodePort values, a direct DSN, or a new override.

One `provision_generation` invocation clones a disposable `srql-fixtures` database for every
ordinary lane -- `integration_tests_async` and `integration_tests_serial_0` through
`integration_tests_serial_6` -- and the lanes are then selected by tag. The async target runs at
`max_cases=8`; each serial target runs at `max_cases=1`; every lane receives its own clone. The
large-ingestion gate uses `provision_generation_large_ingestion` for its dedicated database.
Demo and production are never valid targets for this lifecycle.

## Create A Workstation Scratch Database

Create an isolated scratch database through the reachable NodePort endpoint. The direct
`SERVICERADAR_TEST_DATABASE_URL` used below is for this focused Mix workflow only; it does not
configure a guarded Bazel lane.

```bash
DB="codex_${USER:-agent}_$(date +%s)_$$"
PGPASSWORD="$ADMIN_PASS" psql \
  "host=$TLS_SERVER_NAME hostaddr=$DB_HOST port=$DB_PORT dbname=postgres user=$ADMIN_USER sslmode=verify-full sslrootcert=$CA_FILE" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE $DB"
```

Run current branch migrations with `mix serviceradar.db.migrate`, not `mix ecto.migrate`
(see AGENTS.md): on an empty database it applies the committed baseline instead of replaying
every migration, and it records the applied versions in `platform.ash_schema_migrations` as well,
so web-ng's migrations gate accepts the database. It needs a pool of at least 2, because the
migration lock holds one connection while the migrator uses another; the queue settings keep it
from timing out when the workstation or the fixture is under load:

```bash
cd elixir/serviceradar_core
SERVICERADAR_TEST_DATABASE_URL="postgres://${ADMIN_USER}:${ADMIN_PASS_ENC}@${DB_HOST}:${DB_PORT}/${DB}?sslmode=verify-full" \
SRQL_TEST_DATABASE_SERVER_NAME="$TLS_SERVER_NAME" \
SRQL_TEST_DATABASE_CA_CERT_FILE="$CA_FILE" \
SERVICERADAR_TEST_DATABASE_POOL_SIZE=2 \
SERVICERADAR_TEST_DATABASE_QUEUE_TARGET_MS=10000 \
SERVICERADAR_TEST_DATABASE_QUEUE_INTERVAL_MS=10000 \
MIX_ENV=test mix serviceradar.db.migrate
```

The test configuration (`config/test_database_guard.exs`) refuses any database whose name does
not match `codex_[a-z0-9_]+` (lowercase only; `sr_core_test_*` is reserved for CI lanes), so keep
the prefix from the `CREATE DATABASE` step above.

## Run Focused Tests

Use the same database URL and small pool. Add queue settings for slower fixture runs:

```bash
cd elixir/serviceradar_core
SERVICERADAR_TEST_DATABASE_URL="postgres://${ADMIN_USER}:${ADMIN_PASS_ENC}@${DB_HOST}:${DB_PORT}/${DB}?sslmode=verify-full" \
SRQL_TEST_DATABASE_SERVER_NAME="$TLS_SERVER_NAME" \
SRQL_TEST_DATABASE_CA_CERT_FILE="$CA_FILE" \
SERVICERADAR_TEST_DATABASE_POOL_SIZE=1 \
SERVICERADAR_TEST_DATABASE_QUEUE_TARGET_MS=10000 \
SERVICERADAR_TEST_DATABASE_QUEUE_INTERVAL_MS=10000 \
SERVICERADAR_TEST_SANDBOX_MODE=shared \
MIX_ENV=test mix test path/to/test_file.exs
```

For compile-only validation:

```bash
cd elixir/serviceradar_core
MIX_ENV=test mix compile --warnings-as-errors
```

## Common Failures

- For a scratch database, `pg_hba.conf rejects ... no encryption`: require TLS and provide the
  fixture CA.
- `hostname check failed`: connect through `hostaddr=$DB_HOST` while validating
  `host=$TLS_SERVER_NAME`, or set `SRQL_TEST_DATABASE_SERVER_NAME` for Elixir.
- `No route to host` for the LoadBalancer IP: try the NodePort on a routeable node IP such as `192.168.10.31`.
- `connection refused` on a NodePort: rerun host discovery; the selected node may not be reachable from the workstation.
- `column ... does not exist`: the database is stale; create a scratch database and run `mix serviceradar.db.migrate` with the same pool and queue settings as the migrate step above.
- `Postgrex expected %Postgrex.INET{}` for string parameters: cast through text in SQL, for example `($1::text)::cidr` or `($2::text)::inet`, or pass the project native CIDR type.
- If no NodePort route works, fallback to `kubectl port-forward -n srql-fixtures svc/srql-fixture-rw 15436:5432`, set `DB_HOST=127.0.0.1 DB_PORT=15436`, and reuse the same commands. Expect possible dropped forwards during long migrations.

## Cleanup

After tests finish, drop the scratch database:

```bash
PGPASSWORD="$ADMIN_PASS" psql \
  "host=$TLS_SERVER_NAME hostaddr=$DB_HOST port=$DB_PORT dbname=postgres user=$ADMIN_USER sslmode=verify-full sslrootcert=$CA_FILE" \
  -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $DB"

rm -f "$CA_FILE"
```

## Repository-wide fixture and validation rules

## SRQL Fixture Integration Tests

**Database-backed tests run only against a scratch database on the CNPG in the
`srql-fixtures` namespace (kube context `carverauto`), never against a local Postgres.**
Do not install, start, or connect to a workstation Postgres (Homebrew, `/tmp:5432`,
`localhost:5432`) and do not start the Docker Compose stack to get one, even if a server
happens to be running: it lacks the TimescaleDB and AGE extensions and is not the fixture.
This applies to every agent, including review and test agents in a validation pipeline.

**Validation-pipeline test agents do not compile Elixir apps or build databases.** In a
no-mistakes (or similar) Test step, do not cold-compile `serviceradar_core` or `web-ng`,
and do not create, migrate, or run tests against a scratch database: on this workstation
that takes most of an hour and duplicates two checks that already exist, the coordinating
session's scratch-database run before it submits, and BazelCI's in-cluster integration
lanes in the CI step. Limit the Test step to checks that finish in minutes (reading the
diff, targeted Go/Rust/Python/JS tests, `python3 -m unittest
build/contracts/ci_heavy_gate_contract_test.py`), and report database-backed scenarios as
untested with that reason. The step has a short timeout by design and fails fast.

Use the `srql-fixtures-db-tests` skill when `elixir/serviceradar_core` integration tests
need the shared CNPG/AGE fixture. The guarded lifecycle runs only in the in-cluster
BuildBuddy workflows (`BazelCI`, `LargeIngestionGate`, `IntegrationBenchmark*`). There is
deliberately no orchestration script; the caller invokes each step in order:
`sweep_stale_dbs -> cleanup_generations -> prepare_generation -> migrate_generation (only on
needs_migration) -> prepare_generation (must be ready) -> provision_generation -> tests ->
teardown_db -> release_generation`.

**Schemas come from immutable per-digest generations.** `//build/schema_template:manifest`
hashes the migrations, baseline, helpers and construction inputs; `prepare_generation` reuses
or starts building `sr_tpl_<first 48 hex of that digest>`, and
`//elixir/serviceradar_core:migrate_generation` replays every migration into a new one. A
ready generation is never written again, so a branch's unmerged migrations get their own
generation and never reach the schema another branch clones. Capacity, retention and lease
length live in `build/schema_template/policy.json`; `cleanup_generations` reclaims only
generations idle past retention with no live lease and no connections. Contract and recovery:
[docs/docs/ci-schema-templates.md](docs/docs/ci-schema-templates.md).

**`sr_core_template` is a frozen rollback artifact. Do not write it.** No workflow migrates or
clones it. Its writers (`//elixir/serviceradar_core:migrate_template`,
`//rust/integration-db:prepare_template`, `//rust/integration-db:reset_template`) still refuse
without `--//build:template_authority=true`, and `//build/contracts:ci_heavy_gate_contract_test`
fails if any active workflow passes that flag or names those targets. Never pass it while it
exists to get past a refusal: writing the shared singleton from a branch is what once left
seven unmerged migrations in it and turned every other pull request red. The accepted
retirement plan deletes the writers and the flag; after it lands, rolling back to the
singleton lifecycle means reverting the retirement code first, then restoring the callers.

Step order, run-id and credential rules, the BazelCI merge-tree caveat and cleanup checks:
[docs/agent-runbooks.md](docs/agent-runbooks.md).
