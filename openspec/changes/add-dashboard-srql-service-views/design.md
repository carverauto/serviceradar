# Design: Dashboard SRQL service views

## Context
The current SRQL `in:services` entity is backed by `platform.service_status` and already supports service status rows plus `rollup_stats:availability` via `platform.services_availability_5m`. That is enough for basic availability cards, but dashboard packages need richer, semantically named datasets:

- `service_availability`: latest service check state, dashboard-friendly status labels, latency, summaries, and observed time.
- `monitored_services`: service inventory rows, one row per service identity, suitable for tables and selector lists.
- `slo_evaluations`: derived or persisted SLO pressure rows, suitable for error-budget and burn-rate panels.

These names should not be LiveView-only aliases. They should parse and execute through SRQL so package frames, authored dashboards, `/api/query`, and tests share the same behavior.

## Goals
- Make the previously bundled dashboard frames execute successfully through the real SRQL backend.
- Keep the field contracts stable enough for first-party dashboard packages and authored dashboards.
- Prefer existing service status and availability read models over new persistence.
- Add platform-schema read models only when the entity needs a stable shape that cannot be expressed cleanly in Rust query builders alone.
- Keep unsupported fields explicit: unknown filters and sort fields must return clear SRQL errors.

## Non-Goals
- Building a full generic SLO product in this change.
- Replacing the existing `in:services` entity.
- Adding customer/multitenant scoping. ServiceRadar remains single-deployment.
- Adding dashboard-only query parsing outside SRQL.

## Entity Contracts

### `in:service_availability`
Backed by `platform.service_status` plus availability aggregates where useful.

Initial fields:
- `uid`: stable deterministic ID derived from gateway/agent/service identity.
- `service_name`
- `service_key`: stable service identity key.
- `service_kind`: service type/check type.
- `descriptor_id`: normalized descriptor for the check source when known.
- `status`: `ok`, `warning`, `critical`, or `unknown`.
- `available`: boolean availability.
- `response_time_ms`: parsed latency when available.
- `summary`: user-facing status message.
- `last_observed_at`: latest service status timestamp.
- `gateway_id`, `agent_id`, `partition`

Supported filters should include `status`, `available`, `service_name`, `service_key`, `service_kind`, `gateway_id`, `agent_id`, `partition`, and `time`.

### `in:monitored_services`
Backed by latest distinct service identities from `platform.service_status` or a platform-schema view over it.

Initial fields:
- `uid`
- `display_name`
- `service_key`
- `service_kind`
- `protocol`
- `host`
- `port`
- `status`
- `available`
- `last_observed_at`
- `gateway_id`, `agent_id`, `partition`

Supported filters should include identity, kind, availability, gateway/agent/partition, and time filters.

### `in:slo_evaluations`
Backed initially by derived SLO evaluations from service availability windows. If the derivation becomes too complex or needs user-configured SLO targets, add a platform-schema SLO settings/evaluation read model in a later change.

Initial fields:
- `uid`
- `slo_key`
- `slo_name`
- `owner`
- `compliance_state`
- `severity`
- `budget_remaining_basis_points`
- `burn_rate_short`
- `projected_exhaustion_at`
- `evaluated_at`
- `service_key`, `service_kind`, `partition`

The initial implementation may use default service availability targets and rolling windows, but it must be deterministic, documented in tests, and clearly marked as derived. Queries with `rollup_stats:slo_error_budget` should return dashboard KPI fields required by the Service Availability NOC package.

## SRQL Control Tokens
Control tokens such as `sort:`, `limit:`, `time:`, `stats:`, and `rollup_stats:` must be interpreted by the SRQL parser/planner or ignored only by local UI filters that are explicitly not SRQL engines. Backend SRQL must preserve normal validation: unsupported control values should produce actionable errors instead of silently falling through as text.

## Rollout Strategy
1. Implement backend entity support and tests first.
2. Re-enable the Service Availability NOC dashboard frames against those entities.
3. Verify package frame execution through the web-ng dashboard host path.
4. Deploy to demo only after SRQL and dashboard package checks pass.
