## Context

- Integration sources are stored in `integration_sources` and delivered to agents through agent-gateway `GetConfig` payloads.
- The demo environment runs a faker Armis API (`serviceradar-faker`) and expects the agent to execute Armis discovery on a schedule.
- Current demo behavior shows no sync execution, and the agent codebase does not apply integration source config.

## Goals / Non-Goals

- Goals:
  - Execute Armis integration runs in the agent using the IntegrationSource config.
  - Emit sync lifecycle updates (`last_sync_at`, `last_sync_result`, `last_error_message`, `sync_status`) for UI visibility.
  - Make demo troubleshooting straightforward with clear logs and UI indicators.
- Non-Goals:
  - Implement new integration types beyond Armis in this change (beyond necessary scaffolding).
  - Add multi-tenant routing or bypass modes.

## Decisions

- Build an embedded sync runtime inside the Go agent process that:
  - Parses `config_json` sources into `models.SourceConfig`.
  - Schedules per-source discovery/poll loops using per-source intervals when set.
  - Emits device updates through the existing agent-gateway StreamStatus pathway, including `sync_service_id` and `source` fields.
- Use core-side IntegrationSource actions (`sync_start`, `sync_success`, `sync_failed`) when ingesting updates so status and error fields remain authoritative.
- Log sync lifecycle events at INFO with source name, source_type, and durations for demo debugging.

## Risks / Trade-offs

- Additional load in the agent process; must cap concurrency and respect rate limits.
- Config changes must reliably restart or reschedule sync loops without duplicate runners.
- Errors should be surfaced without spamming the UI or log noise.

## Migration Plan

1. Implement embedded sync runtime and Armis adapter behind a config flag.
2. Roll out updated agent image in demo and enable the runtime flag.
3. Verify that `integration_sources.last_sync_at` and `last_sync_result` populate and the UI shows recent runs.
4. Remove legacy or unused sync wiring if no longer needed.

## Open Questions

- Should we add a manual "Run now" action for integrations in the UI?
- Do we want a per-source concurrency limit or global sync worker pool?
- Should failures include structured error codes (auth, network, rate-limit) for UI badges?
