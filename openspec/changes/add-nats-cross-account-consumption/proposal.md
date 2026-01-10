# Change: Cross-Account NATS Consumption for Platform ETL

## Why
Tenant NATS accounts isolate JetStream per account, so shared consumers (serviceradar-zen, event-writer, future ETL) cannot see tenant streams today. Subject mapping only rewrites within the same account and does not expose data cross-account. We need a secure, supported path for platform ETL to read tenant logs/events without weakening isolation.

## What Changes
- Add stream exports on tenant accounts for logs/events/otel subjects.
- Add platform account imports for each tenant export so shared consumers can read prefixed subjects.
- Update tenant provisioning to add/remove platform imports when tenant accounts are created or revoked.
- Update shared consumers (zen) to subscribe to tenant-prefixed subjects and extract tenant slug from the subject.
- Document and test cross-account consumption behavior.

## Impact
- Affected specs: nats-cross-account-consumption
- Affected code: pkg/nats/accounts, elixir/serviceradar_core NATS account provisioning, NATS config/helm, zen config/deployments
