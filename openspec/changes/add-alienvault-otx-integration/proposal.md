# Change: Add AlienVault OTX threat intelligence integration

## Why
ServiceRadar already stores historical NetFlow and DNS-derived telemetry. When AlienVault OTX publishes or updates indicators today, operators need ServiceRadar to answer whether monitored hosts contacted those indicators during the historical retention window, not only after new blocking rules are deployed.

## What Changes
- Add deployment-scoped AlienVault OTX settings with encrypted API key storage and Settings UI controls.
- Add an AshOban-backed OTX sync job that imports subscribed OTX pulses and indicators through the OTX DirectConnect API.
- Normalize OTX indicators into CNPG tables for querying and deduplication.
- Optionally persist raw OTX pulse/API payload snapshots in NATS Object Store for audit and replay; normalized CNPG rows remain the required data path.
- Add a retroactive hunt worker that queries recent NetFlow/DNS history for newly imported indicators and records findings.
- Add operator visibility for sync health, imported indicator counts, retrohunt status, and historical matches.

## Impact
- Affected specs: alienvault-otx-threat-intel, job-scheduling, build-web-ui
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/observability/**`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
  - Oban cron/job registry and tests

## Notes
- The OTX API key must be treated as a secret. It should be entered through encrypted settings or injected from deployment secrets, never committed to the repo.
- The user-provided key in the conversation should be rotated before production use because it has been exposed outside the target secret store.
