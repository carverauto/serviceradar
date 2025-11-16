# Docker Compose Login Fails with 500 After Reboot

This runbook captures the recurring auth failures we see right after bringing
the Docker Compose stack up on a freshly rebooted dev host.

## What Happens
- The `serviceradar-cnpg` container generates TLS keys, initializes the
  Timescale extensions, and replays the embedded migrations on first boot. This
  work can take a few minutes when the data directory was wiped or the host is
  under heavy IO load.
- While CNPG is still initializing, `serviceradar-core` continuously restarts
  because the migrations cannot connect to Postgres on `:5432`.
- The web UI and Kong are up, but every `/auth/login` (and the JWKS fetch) hits
  core while it is still restarting, resulting in HTTP 500 responses.

## How to Recognize It
- `docker compose ps` shows `serviceradar-cnpg` as `unhealthy` and
  `serviceradar-core` stuck in `health: starting`.
- `docker compose logs core | tail` contains lines like:
  ```
  Fatal error: database error: failed to run database migrations:
  failed to create migrations table: dial tcp 172.18.0.7:5432:
  connect: connection refused
  ```
- `docker compose logs cnpg --tail 20` loops on:
  ```
  Waiting for CNPG bootstrap to finish (pg_isready still failing)...
  ```

## Mitigation
1. Make sure the database container is up-to-date and restart it explicitly so
   it does not share a zombie process from a previous compose run:
   ```
   docker compose up -d cnpg
   ```
2. While waiting, watch its logs until you see `database system is ready to
   accept connections` and `created extension "timescaledb"` messages:
   ```
   docker compose logs -f cnpg | rg -i 'ready|extension'
   ```
3. Once CNPG is healthy, core finishes the migrations on the next attempt and
   the login endpoint starts returning 200s. No manual restarts are required,
   but you can confirm with:
   ```
   docker compose logs core --tail 20
   docker compose logs web  --tail 20
   ```
4. If the data directory was removed, run `make cnpg-migrate` (with
   `CNPG_HOST=localhost CNPG_PORT=55432` if you port-forwarded) so the Timescale
   schema is reseeded immediately.

### UI Port Reminder
By default the compose nginx binds to host port `80`. If the port is already
occupied on your host, either stop the conflicting service or set
`SERVICERADAR_HTTP_PORT=<alternate>` before running `docker compose up`. The
common culprit is the distro’s own nginx service; disable it once and the stack
will reuse port 80 every boot:
```
sudo systemctl disable --now nginx
docker compose up -d nginx
```

## Longer-Term Fix Ideas
- Commit the initialized CNPG data directory as part of the dev VM images so
  the first boot does not have to run `initdb` + Timescale extension installs.
- Mount `${PWD}/dist/cnpg` as the Postgres data directory to persist the
  initial bootstrap across reboots.
- Update the web UI to surface a clearer “database still starting” banner
  instead of surfacing raw 500 errors during the warm-up window.
