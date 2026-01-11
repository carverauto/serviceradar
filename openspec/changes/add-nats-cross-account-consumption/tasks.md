# Tasks: Cross-Account NATS Consumption

> Status: paused (superseded by per-tenant zen consumers in add-nats-tenant-isolation)

## 1. Account Exports and Imports
- [~] 1.1 Add stream exports to tenant account JWT generation (logs/events/otel)
- [~] 1.2 Add platform account imports per tenant (logs/events/otel)
- [~] 1.3 Update tenant provisioning workflow to add/remove platform imports
- [~] 1.4 Validate resolver updates for platform + tenant JWTs
- [~] 1.5 Create JetStream source/mirror streams in PLATFORM for tenant streams
- [~] 1.6 Mirror tenant KV rule streams into PLATFORM for zen watchers

## 2. Shared Consumer Updates (Zen)
- [~] 2.1 Update zen subscriptions to tenant-prefixed subjects (`*.logs.>`, `*.events.>`, `*.otel.>`)
- [~] 2.2 Ensure zen extracts tenant slug from subject prefix for routing
- [~] 2.3 Update zen deployment configs (helm/docker) to use platform imports

## 3. Verification and Docs
- [~] 3.1 Add end-to-end checklist for cross-account ingestion
- [~] 3.2 Document operator steps for exporting/importing tenant streams
- [~] 3.3 Document JetStream source/mirror configuration (streams + KV)
