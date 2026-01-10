# Change: Cross-Account NATS Consumption for Platform ETL

## Why
Tenant NATS accounts isolate JetStream per account, so shared consumers (serviceradar-zen, event-writer, future ETL) cannot see tenant streams today. Subject mapping only rewrites within the same account and does not expose data cross-account. We need a secure, supported path for platform ETL to read tenant logs/events without weakening isolation.

## Status
Superseded by per-tenant zen consumers in `add-nats-tenant-isolation`. We are
not pursuing cross-account JetStream consumption at this time.

## What Changes
- No implementation planned while per-tenant zen is the chosen approach.

## Impact
- Affected specs: nats-cross-account-consumption
- Affected code: pkg/nats/accounts, elixir/serviceradar_core NATS account provisioning, NATS config/helm, zen config/deployments
