---
name: demo-cnpg-local-web-ng
description: Run ServiceRadar web-ng locally against the live Kubernetes `demo` CNPG database for dashboard, SRQL, services, and UI testing. Use when a task asks to test with live demo data, run local Phoenix against demo CNPG, validate dashboard authoring with Playwright, or avoid fragile kubectl port-forward database access.
---

# Demo CNPG Local Web-NG

Use this skill when local `elixir/web-ng` must run against the live `demo`
namespace CNPG database instead of Docker Compose or `srql-fixtures`.

## Quick Start

From the ServiceRadar repo root:

```bash
.agents/skills/demo-cnpg-local-web-ng/scripts/start-local-web-ng.sh
```

The script:

- reads current `demo/serviceradar-db-credentials` without printing the password;
- tries the GitOps-managed internal LoadBalancer VIP `192.168.6.82:5432`;
- falls back to the current CNPG primary node's NodePort paths, including `cnpg-rw-internal-lb` and `cnpg-local-dev`;
- validates TCP reachability before starting Phoenix;
- starts `mix phx.server` in `elixir/web-ng` with small DB pools and long queue windows for WAN/LAN testing.

To only verify the live DB route without starting Phoenix:

```bash
.agents/skills/demo-cnpg-local-web-ng/scripts/start-local-web-ng.sh --check
```

Then use `$playwright-cli` against `http://localhost:4000`.

## Known Access Paths

Permanent GitOps-managed objects:

- Service: `demo/cnpg-rw-internal-lb`
- Intended VIP: `192.168.6.82:5432`
- NetworkPolicy: `demo/cnpg-allow-oracle-test-postgres`

Current known-good fallback from `192.168.2.134`:

- `10.0.2.11:32040` via `demo/cnpg-rw-internal-lb`
- `10.0.2.11:30455` via `demo/cnpg-local-dev`

If `192.168.6.82:5432` fails but the NodePort path works, treat it as a
routing/L2 issue, not a web-ng or CNPG issue.

## Browser Validation

Use the `playwright-cli` skill for screenshots and smoke tests:

```bash
playwright-cli open http://localhost:4000/dashboards
playwright-cli screenshot --filename=tmp/demo-cnpg-dashboard-library.png
```

For dashboard authoring matrix checks:

```bash
playwright-cli run-code --filename elixir/web-ng/test/playwright/dashboard_authoring_matrix.playwright.js
```

Keep screenshots under `tmp/` or `.playwright-cli/`; do not commit them.

## Notes

- Prefer this skill over `kubectl port-forward` for web-ng testing against `demo`; port-forward is fragile under Phoenix startup connection churn.
- Re-read Kubernetes secrets each run. Demo credentials can rotate during releases.
- Use `CNPG_HOST_OVERRIDE` and `CNPG_PORT_OVERRIDE` only when explicitly testing a specific route.
- Stop stale local Phoenix servers before starting a new one if port `4000` is already occupied.
