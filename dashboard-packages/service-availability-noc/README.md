# Service Availability NOC Dashboard

This first-party dashboard package ships with ServiceRadar and is authored with
the ServiceRadar Dashboard SDK. It provides a NOC-facing view of service
availability, SLO compliance, error-budget pressure, and active service state.

It is designed to pair with the service monitoring demo seed:

```bash
psql "$DATABASE_URL" -f docs/static/examples/service-monitoring-demo-seed.sql
```

## Frames

The package declares these SRQL frames:

- `availability_rollup`: `in:service_availability ... rollup_stats:availability`
- `attention_services`: `in:service_availability ... status:(critical,unknown,warning)`
- `service_inventory`: `in:monitored_services ...`
- `slo_evaluations`: `in:slo_evaluations ...`
- `slo_budget_rollup`: `in:slo_evaluations rollup_stats:slo_error_budget`

Runtime filters rebuild the frame queries through the dashboard SDK query-state
helper. Operators can filter by NOC group, service kind, service state, and SLO
owner without editing the package.

## Build

```bash
npm install
npm run validate
npm run build
```

The build writes `dist/renderer.js`, `dist/manifest.json`, and copied sample
fixtures. The manifest is the package artifact that ServiceRadar imports and
verifies before exposing the dashboard route.
