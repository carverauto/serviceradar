## Context
Sweep group creation currently runs a change that calls `Oban.insert/3` in the core app. When the core app does not have a running Oban instance/config, the change raises, aborting the sweep group create/update flow and crashing the LiveView process.

## Goals / Non-Goals
- Goals:
  - Allow sweep groups to be created/updated even if Oban is unavailable.
  - Provide clear operator feedback that scheduling is deferred.
  - Ensure schedules are eventually created once Oban becomes available.
- Non-Goals:
  - Redesign sweep scheduling semantics.
  - Change existing sweep group data model beyond what is required to track deferred scheduling.

## Decisions
- Decision: Guard Oban inserts and treat missing Oban as a recoverable condition.
  - Rationale: Sweep configuration should persist independently of the scheduler process.
- Decision: Reconcile enabled sweep groups when Oban becomes available.
  - Rationale: Deferred scheduling must be resolved without manual re-save.

## Risks / Trade-offs
- Risk: Deferred scheduling may remain unscheduled if reconciliation is not triggered.
  - Mitigation: Run reconciliation at app start and optionally on a periodic schedule.

## Migration Plan
- Deploy code changes.
- Verify that sweep group creation works with Oban disabled, and that enabling Oban triggers reconciliation.

## Open Questions
- Should reconciliation be owned by web-ng, core, or a dedicated scheduler service?
- Should UI show a persistent status badge vs a one-time warning flash?
