---
name: srql-fixtures-db-tests
description: Run ServiceRadar Elixir database tests against the Kubernetes CNPG instance in the `srql-fixtures` namespace. Use when local localhost PostgreSQL is unavailable, when tests need current branch migrations, or when a user asks to use the srql-fixtures database for DB-backed validation. Covers the Bazel serviceradar_core integration lifecycle, scratch database creation, TLS-verified NodePort connections, migrations, cleanup, and secret hygiene.
---

# SRQL Fixtures DB Tests

Use this skill to run DB-backed Elixir tests against the shared CNPG cluster in the Kubernetes
`srql-fixtures` namespace. Use the Bazel lifecycle for the sharded `serviceradar_core` integration
suite. Prefer a separate scratch database for an individual Mix test that is not in that suite.

## Guardrails

- Do not print database passwords or full URLs containing credentials.
- Use a scratch database named with a unique prefix, for example `codex_<topic>_<timestamp>_<pid>`.
- Verify the CNPG certificate. For a NodePort IP, set the certificate's DNS name through both
  `PGSSLSERVERNAME` (Rust) and `SRQL_TEST_DATABASE_SERVER_NAME` (Elixir), and use
  `sslmode=verify-full` with the fixture CA.
- Prefer the existing NodePort/LoadBalancer service over `kubectl port-forward`; port-forwarding to CNPG is flaky and should be fallback only.
- Keep the Ecto sandbox pool small for an individual scratch-DB test. Do not force the sharded
  integration suite below its configured pool floor; its alert-engine fanout needs at least 12.
- Drop the scratch database when finished unless the user asks to keep it for inspection.

## Discover Primary And Credentials

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
kubectl get secret srql-fixture-ca -n srql-fixtures -o jsonpath='{.data.ca\.crt}' | \
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

## Run A Serviceradar Core Bazel Shard

The supported lifecycle is an explicit sequence of Bazel targets. There is no wrapper script and
Bazel does not order a `test_suite` or provide a finalizer across invocations:

```text
sweep -> prepare -> migrate if pending -> provision -> shard -> teardown
```

Configure the credential-only fixture environment and the Bazel flags in one shell. The credential
target writes a private, per-run env file; it does not print the DSNs. Replace `DB_HOST` and
`DB_PORT` with the reachable NodePort selected above. The EXIT trap is the caller-owned finalizer
Bazel cannot provide across invocations:

```bash
set -euo pipefail

export SRQL_FIXTURE_HOST="$DB_HOST"
export SRQL_FIXTURE_PORT="$DB_PORT"
export SRQL_FIXTURE_SSLMODE=verify-full
export PGSSLSERVERNAME=srql-fixture-rw.srql-fixtures.svc.cluster.local
export SRQL_TEST_DATABASE_SERVER_NAME="$PGSSLSERVERNAME"

run_entropy="${HOSTNAME:-workstation}-$(date +%s)-$$-${RANDOM:-0}"
run_checksum="$(printf '%s' "$run_entropy" | cksum | awk '{print $1}')"
export GITHUB_RUN_ID="$(date +%s)${run_checksum}"
export GITHUB_RUN_ATTEMPT=1
COMMON=(-c opt --//build:enable_integration_tests)
if [ -f .bazelrc.remote ]; then
  COMMON+=(--config=cache_only)
fi

TEST_FLAGS=("${COMMON[@]}" --strategy=TestRunner=local --test_tag_filters= \
  --config=database_env --test_output=errors --nocache_test_results --flaky_test_attempts=1)
export SERVICERADAR_FIXTURE_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/serviceradar-fixture-env.XXXXXX")"
TEMPLATE_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/sr-core-template-output.XXXXXX")"
provision_attempted=0

cleanup() {
  status=$?
  trap - EXIT INT TERM
  set +e
  teardown_status=0
  credential_cleanup_status=0
  if [ "$provision_attempted" -eq 1 ]; then
    bazel test "${TEST_FLAGS[@]}" //rust/integration-db:teardown_db
    teardown_status=$?
  fi
  rm -f "$SERVICERADAR_FIXTURE_ENV_FILE" "$TEMPLATE_OUTPUT" || credential_cleanup_status=$?
  if [ -n "${CA_FILE:-}" ]; then
    rm -f "$CA_FILE" || credential_cleanup_status=$?
  fi
  if [ "$status" -ne 0 ]; then
    exit "$status"
  fi
  if [ "$teardown_status" -ne 0 ]; then
    exit "$teardown_status"
  fi
  exit "$credential_cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bazel run "${COMMON[@]}" --build_tag_filters= //:buildbuddy_setup_fixture_env
set -a
. "$SERVICERADAR_FIXTURE_ENV_FILE"
set +a

# The base must remain in SRQL_TEST_* so integration_env.exs can derive the shard database.
unset SERVICERADAR_TEST_DATABASE_URL SERVICERADAR_TEST_ADMIN_URL

bazel test "${TEST_FLAGS[@]}" //rust/integration-db:sweep_stale_dbs
GITHUB_OUTPUT="$TEMPLATE_OUTPUT" \
  bazel run "${COMMON[@]}" --build_tag_filters= //rust/integration-db:prepare_template

if rg -qx 'needs_migration=true' "$TEMPLATE_OUTPUT"; then
  bazel test "${TEST_FLAGS[@]}" //elixir/serviceradar_core:migrate_template
fi

provision_attempted=1
bazel test "${TEST_FLAGS[@]}" //rust/integration-db:provision_db_s2
shard_status=0
bazel test "${TEST_FLAGS[@]}" //elixir/serviceradar_core:integration_tests_s2 || shard_status=$?
teardown_status=0
bazel test "${TEST_FLAGS[@]}" //rust/integration-db:teardown_db || teardown_status=$?
if [ "$teardown_status" -eq 0 ]; then
  provision_attempted=0
fi
if [ "$shard_status" -ne 0 ]; then
  exit "$shard_status"
fi
exit "$teardown_status"
```

Use the authenticated cache without selecting the Linux RBE platform when an ignored mode-0600
`.bazelrc.remote` credential is present. Without that file, `COMMON` omits
`--config=cache_only` for a fully local build.

Use matching suffixes from `s0` through `s7`. For all shards, use unsuffixed `provision_db` and
`integration_tests`. Do not add `--remote_upload_local_results=false` to the workstation command:
`--nocache_test_results` keeps mutable test outcomes out of the test cache while local compilation
misses remain eligible to populate the shared cache. CI may suppress local-result uploads because
its compilation actions execute remotely.

Always run `teardown_db` after provisioning, even when a shard is red. If the workstation is
killed before teardown, the next `sweep_stale_dbs` invocation is the backstop.

## Create A Scratch Database

Create an isolated scratch database through the reachable NodePort endpoint:

```bash
DB="codex_${USER:-agent}_$(date +%s)_$$"
PGPASSWORD="$ADMIN_PASS" psql \
  "host=$TLS_SERVER_NAME hostaddr=$DB_HOST port=$DB_PORT dbname=postgres user=$ADMIN_USER sslmode=verify-full sslrootcert=$CA_FILE" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE $DB"
```

Run current branch migrations:

```bash
cd elixir/serviceradar_core
SERVICERADAR_TEST_DATABASE_URL="postgres://${ADMIN_USER}:${ADMIN_PASS_ENC}@${DB_HOST}:${DB_PORT}/${DB}?sslmode=verify-full" \
SRQL_TEST_DATABASE_SERVER_NAME="$TLS_SERVER_NAME" \
SRQL_TEST_DATABASE_CA_CERT_FILE="$CA_FILE" \
SERVICERADAR_TEST_DATABASE_POOL_SIZE=1 \
MIX_ENV=test mix ecto.migrate
```

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

- `pg_hba.conf rejects ... no encryption`: require TLS and provide the fixture CA.
- `hostname check failed`: connect through `hostaddr=$DB_HOST` while validating
  `host=$TLS_SERVER_NAME`, or set `SRQL_TEST_DATABASE_SERVER_NAME` for Elixir.
- `No route to host` for the LoadBalancer IP: try the NodePort on a routeable node IP such as `192.168.10.31`.
- `connection refused` on a NodePort: rerun host discovery; the selected node may not be reachable from the workstation.
- `column ... does not exist`: the database is stale; create a scratch database and run `mix ecto.migrate`.
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
