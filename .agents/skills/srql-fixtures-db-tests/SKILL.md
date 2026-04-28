---
name: srql-fixtures-db-tests
description: Run ServiceRadar Elixir database tests against the Kubernetes CNPG instance in the `srql-fixtures` namespace. Use when local localhost PostgreSQL is unavailable, when tests need current branch migrations, or when a user asks to use the srql-fixtures database for DB-backed validation. Covers scratch database creation, TLS-required NodePort connections, migrations, focused test commands, cleanup, and secret hygiene.
---

# SRQL Fixtures DB Tests

Use this skill to run DB-backed Elixir tests against the shared CNPG cluster in the Kubernetes `srql-fixtures` namespace. Prefer a scratch database for branch validation so current migrations can run without mutating shared fixture databases.

## Guardrails

- Do not print database passwords or full URLs containing credentials.
- Use a scratch database named with a unique prefix, for example `codex_<topic>_<timestamp>_<pid>`.
- Point tests at the scratch database with `sslmode=require`; CNPG rejects non-encrypted client connections.
- Prefer the existing NodePort/LoadBalancer service over `kubectl port-forward`; port-forwarding to CNPG is flaky and should be fallback only.
- Keep the Ecto sandbox pool small over the shared fixture DB; use `SERVICERADAR_TEST_DATABASE_POOL_SIZE=1` or `2`.
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
```

Pick a reachable host/port. From the usual workstation, `192.168.10.31:30818` has been reachable while the advertised LoadBalancer IP may not be:

```bash
NODEPORT=$(kubectl get svc srql-fixture-rw-ext -n srql-fixtures -o jsonpath='{.spec.ports[0].nodePort}')

for host in 192.168.10.31 192.168.10.96 $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'); do
  if timeout 4 bash -c "PGPASSWORD=\"$ADMIN_PASS\" psql \"postgresql://${ADMIN_USER}@${host}:${NODEPORT}/postgres?sslmode=require\" -v ON_ERROR_STOP=1 -Atc 'select 1' >/dev/null 2>&1"; then
    DB_HOST="$host"
    DB_PORT="$NODEPORT"
    break
  fi
done

test -n "${DB_HOST:-}" || { echo "no reachable srql-fixtures NodePort host"; exit 1; }
```

## Create A Scratch Database

Create an isolated scratch database through the reachable NodePort endpoint:

```bash
DB="codex_${USER:-agent}_$(date +%s)_$$"
PGPASSWORD="$ADMIN_PASS" psql "postgresql://${ADMIN_USER}@${DB_HOST}:${DB_PORT}/postgres?sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE $DB"
```

Run current branch migrations:

```bash
cd elixir/serviceradar_core
SERVICERADAR_TEST_DATABASE_URL="postgres://${ADMIN_USER}:${ADMIN_PASS_ENC}@${DB_HOST}:${DB_PORT}/${DB}?sslmode=require" \
SERVICERADAR_TEST_DATABASE_POOL_SIZE=1 \
MIX_ENV=test mix ecto.migrate
```

## Run Focused Tests

Use the same database URL and small pool. Add queue settings for slower fixture runs:

```bash
cd elixir/serviceradar_core
SERVICERADAR_TEST_DATABASE_URL="postgres://${ADMIN_USER}:${ADMIN_PASS_ENC}@${DB_HOST}:${DB_PORT}/${DB}?sslmode=require" \
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
- `No route to host` for the LoadBalancer IP: try the NodePort on a routeable node IP such as `192.168.10.31`.
- `connection refused` on a NodePort: rerun host discovery; the selected node may not be reachable from the workstation.
- `column ... does not exist`: the database is stale; create a scratch database and run `mix ecto.migrate`.
- `Postgrex expected %Postgrex.INET{}` for string parameters: cast through text in SQL, for example `($1::text)::cidr` or `($2::text)::inet`, or pass the project native CIDR type.
- If no NodePort route works, fallback to `kubectl port-forward -n srql-fixtures svc/srql-fixture-rw 15436:5432`, set `DB_HOST=127.0.0.1 DB_PORT=15436`, and reuse the same commands. Expect possible dropped forwards during long migrations.

## Cleanup

After tests finish, drop the scratch database:

```bash
PGPASSWORD="$ADMIN_PASS" psql "postgresql://${ADMIN_USER}@${DB_HOST}:${DB_PORT}/postgres?sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $DB"
```
