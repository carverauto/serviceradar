---
name: web-ng-docker-loop
description: Run ServiceRadar `elixir/web-ng` locally against the Docker Compose CNPG database with copied mTLS certs and Docker secrets, then verify dashboard UI changes with Playwright. Use when iterating on web-ng, dashboard package, custom React dashboard, customer WiFi map, SRQL topbar, or browser screenshot behavior without rebuilding the web-ng release image.
---

# Web-NG Docker Loop

Use this skill for fast local UI iteration when Docker Compose is already running the ServiceRadar mTLS stack. Prefer this loop over Bazel/release-image rebuilds until the final Docker parity check.

## Quick Start

From the ServiceRadar repo root:

```bash
.agents/skills/web-ng-docker-loop/scripts/start-local-web-ng.sh
```

The script:
- copies `root.pem`, `db-client.pem`, and `db-client-key.pem` from the Docker web-ng cert mount into `tmp/web-ng-docker-loop/certs/`
- reads the CNPG app password from the running Docker secret without printing it
- validates the local host connection to `localhost:5455`
- syncs Docker filesystem plugin/dashboard package blobs into `tmp/web-ng-docker-loop/plugin-packages/`
- starts `mix phx.server` in `elixir/web-ng` on `http://localhost:4000`

If the app database password in Docker secrets does not match the local CNPG role, rerun once with:

```bash
.agents/skills/web-ng-docker-loop/scripts/start-local-web-ng.sh --repair-app-password
```

That repair path is only for the local Docker Compose stack; it uses the Docker superuser secret to reset the Docker `serviceradar` role to the Docker app secret.

## Dashboard Package Import

After rebuilding a dashboard package, import it into the Docker-backed database without rebuilding web-ng:

```bash
.agents/skills/web-ng-docker-loop/scripts/import-dashboard-package.sh \
  /home/mfreeman/src/example-dashboard/dist/manifest.json \
  /home/mfreeman/src/example-dashboard/dist/renderer.js
```

This imports and enables the package through the running Docker web-ng release RPC, then prints the enabled content hash.
Restart the local loop, or rerun it with the default plugin-storage sync enabled, after importing a new dashboard renderer.

## Browser Checks

Use `$playwright-cli` for interactive inspection and screenshots:

```bash
playwright-cli open http://localhost:4000/dashboards/wifi-network-map
playwright-cli snapshot
playwright-cli screenshot --filename=tmp/wifi-map-local.png
```

If authentication is required, obtain the admin password from `docker compose logs config-updater` without writing it into committed files.

## Notes

- Keep generated certs and screenshots under `tmp/`; do not commit them.
- Stop stale local Phoenix servers before starting a new one: `pkill -f 'mix phx.server'`.
- Use the Docker route (`https://192.168.2.134/...`) only for final parity after local checks pass.
- Run `npm run build:js && npm run build:css` in `elixir/web-ng/assets` after JS/CSS changes before browser checks.
