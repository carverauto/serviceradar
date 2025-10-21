# Docker Compose Login Fails with 500 After Reboot

This runbook captures the recurring auth failures we see right after bringing
the Docker Compose stack up on a freshly rebooted dev host.

## What Happens
- Proton generates fresh 2048-bit DH params on startup and binds HTTPS ports
  only after that work finishes.
- While Proton is still generating, core continuously restarts because the
  migrations cannot reach Proton on `:9440`.
- The web UI and Kong are up, but every `/auth/login` (and the JWKS fetch) hits
  core while it is still restarting, resulting in HTTP 500 responses.

## How to Recognize It
- `docker compose ps` shows `serviceradar-proton` as `unhealthy` and
  `serviceradar-core` stuck in `health: starting`.
- `docker compose logs core | tail` contains lines like:
  ```
  Fatal error: database error: failed to run database migrations:
  failed to create migrations table: dial tcp 172.18.0.7:9440:
  connect: connection refused
  ```
- `docker compose logs proton --tail 20` is stuck on:
  ```
  [Proton Init] Generating DH parameters (this may take a few minutes for security)...
  ```

## Mitigation
1. The `proton-init.sh` entrypoint now caches the generated DH params under
   `/var/lib/proton/dhparam.pem`, so you only pay the cost once per volume.
   Make sure your compose stack is up to date:
   ```
   docker compose up -d proton
   ```
   The first start may take 6–10 minutes while the params are created; after
   that, restarts reuse the cached file and come up immediately.
2. While waiting, you can watch for the container to flip to `healthy`:
   ```
   docker compose ps proton core
   ```
3. Once Proton is healthy, core finishes migrations on the next attempt and the
   login endpoint starts returning 200s. No manual restarts are required.

### UI Port Reminder
By default the compose nginx binds to host port `80`. If the port is already
occupied on your host, either stop the conflicting service or set
`SERVICERADAR_HTTP_PORT=<alternate>` before running `docker compose up`.
The common culprit is the distro’s own nginx service; disable it once and the
stack will reuse port 80 every boot:
```
sudo systemctl disable --now nginx
docker compose up -d nginx
```

## Longer-Term Fix Ideas
- Teach the Proton entrypoint to reuse DH params stored in the shared
  `cert-data` volume so every restart does not regenerate them.
- Consider precomputing the DH params as part of the image build to shorten the
  first-boot delay.
- Update the web UI to surface a clearer “core still starting” banner instead
  of surfacing raw 500 errors during the warm-up window.
