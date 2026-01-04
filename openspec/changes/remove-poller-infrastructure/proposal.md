# Change: Remove poller infrastructure references

## Why
Poller services are fully deprecated and no longer part of the running architecture. Keeping poller references in code, configs, specs, and tests is now misleading, risks cross-tenant leakage, and creates broken pathways in tooling and UI.

## What Changes
- **BREAKING** Remove poller services, resources, configuration paths, and UI surfaces.
- **BREAKING** Migrate gateway persistence to a dedicated `gateways` table (separate from pollers).
- Replace poller-oriented runtime lookups, channel names, and SRQL parameters with gateway/agent equivalents (where required).
- Update OpenSpec requirements to remove poller assumptions and reflect the gateway/agent architecture.
- Clean docker-compose, images, tests, and docs that still reference pollers.

## Impact
- Affected specs: `edge-architecture`, `tenant-isolation`, `kv-configuration`, `service-registry`, `mcp`.
- Affected code: Elixir core (resources, registries, telemetry, onboarding, migrations), web-ng UI and tests, SRQL mappings, Docker compose configs/images, Go/Rust poller artifacts, documentation and runbooks.
