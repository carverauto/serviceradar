# Change: Add logs/events/alerts separation and promotion pipeline

## Why
Operators need a clear model for raw signals versus derived events and actionable alerts. Today syslog, SNMP traps, and internal health messages are inconsistently surfaced in the UI, which makes it hard to build a single, consistent operational workflow.

## What Changes
- Define a signal taxonomy: logs (raw), events (derived OCSF), alerts (stateful escalation).
- Standardize per-tenant promotion from logs to events and from events to alerts, with explicit provenance links.
- Expose three distinct UI panes (logs, events, alerts) with consistent filtering and linking across the chain.
- Document how rule processing and promotion are configured per tenant.

## Impact
- Affected specs: observability-signals (new)
- Affected systems: core-elx ingestion and event/alert generation, SRQL queries over logs/events, web-ng UI
