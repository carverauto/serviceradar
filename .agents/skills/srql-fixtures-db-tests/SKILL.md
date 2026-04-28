---
name: srql-fixtures-db-tests
description: Run ServiceRadar Elixir database tests against the Kubernetes CNPG instance in the `srql-fixtures` namespace. Use when local localhost PostgreSQL is unavailable, when tests need current branch migrations, or when a user asks to use the srql-fixtures database for DB-backed validation. Covers scratch database creation, TLS-required connections, port-forwarding, migrations, focused test commands, cleanup, and secret hygiene.
---

# SRQL Fixtures DB Tests

Use this skill to run DB-backed Elixir tests against the shared CNPG cluster in the Kubernetes `srql-fixtures` namespace. Prefer a scratch database for branch validation so current migrations can run without mutating shared fixture databases.

## Guardrails

- Do not print database passwords or full URLs containing credentials.
- Use a scratch database named with a unique prefix, for example `codex_<topic>_<timestamp>_<pid>`.
- Point tests at the scratch database with `sslmode=require`; CNPG rejects non-encrypted client connections.
- Keep the Ecto sandbox pool small over `kubectl port-forward`; use `SERVICERADAR_TEST_DATABASE_POOL_SIZE=1` or `2`.
- Do not use the external LoadBalancer unless you have verified routeability from the workstation. Prefer `kubectl port-forward` to the primary pod.
- Drop the scratch database when finished unless the user asks to keep it for inspection.

## Discover Primary And Credentials

From the repo root:

```bash
kubectl get pods -n srql-fixtures -l cnpg.io/cluster=srql-fixture -L cnpg.io/instanceRole -o wide
kubectl get secret srql-test-admin-credentials -n srql-fixtures -o json | jq -r '.data | keys[]'
```

Use the `primary` pod for write tests. Read admin credentials into shell variables without echoing the password:

```bash
ADMIN_USER=$(kubectl get secret srql-test-admin-credentials -n srql-fixtures -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl get secret srql-test-admin-credentials -n srql-fixtures -o jsonpath='{.data.password}' | base64 -d)
ADMIN_PASS_ENC=$(printf '%s' "$ADMIN_PASS" | jq -sRr @uri)
```

## Create A Scratch Database

Start a port-forward to the primary pod. Use a fresh local port each time if a stale forward exists.

```bash
kubectl port-forward -n srql-fixtures pod/srql-fixture-2 15436:5432
```

In another shell:

```bash
DB="codex_${USER:-agent}_$(date +%s)_$$"
PGPASSWORD="$ADMIN_PASS" psql "postgresql://${ADMIN_USER}@127.0.0.1:15436/postgres?sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE $DB"
```

Run current branch migrations:

```bash
cd elixir/serviceradar_core
SERVICERADAR_TEST_DATABASE_URL="postgres://${ADMIN_USER}:${ADMIN_PASS_ENC}@127.0.0.1:15436/${DB}?sslmode=require" \
SERVICERADAR_TEST_DATABASE_POOL_SIZE=1 \
MIX_ENV=test mix ecto.migrate
```

If the port-forward drops during migrations or tests, restart it on a new local port and reuse the same scratch database.

## Run Focused Tests

Use the same database URL and small pool. Add queue settings for slower fixture runs:

```bash
cd elixir/serviceradar_core
SERVICERADAR_TEST_DATABASE_URL="postgres://${ADMIN_USER}:${ADMIN_PASS_ENC}@127.0.0.1:15436/${DB}?sslmode=require" \
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

- `pg_hba.conf rejects ... no encryption`: use `?sslmode=require`.
- `connection refused` after a few connections: the port-forward dropped; restart it on a new local port and update the URL.
- `column ... does not exist`: the database is stale; create a scratch database and run `mix ecto.migrate`.
- `Postgrex expected %Postgrex.INET{}` for string parameters: cast through text in SQL, for example `($1::text)::cidr` or `($2::text)::inet`, or pass the project native CIDR type.

## Cleanup

After tests finish, stop the port-forward and drop the scratch database:

```bash
PGPASSWORD="$ADMIN_PASS" psql "postgresql://${ADMIN_USER}@127.0.0.1:15436/postgres?sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $DB"
```

If the original port-forward is gone, start a new one to the primary pod first.
