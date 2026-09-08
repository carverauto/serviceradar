# Change: Reduce redundant agent status pushes

## Why
Agents are repeatedly pushing unchanged sweep status to the gateway (issue #2409), creating unnecessary gRPC traffic and noisy logs without improving observability.

## What Changes
- Update agent status push behavior to be change-driven with a configurable heartbeat.
- Debounce status pushes when no state changes are detected, including sweep status.
- Clarify gateway expectations for less frequent, change-based status updates.

## Impact
- Affected specs: agent-configuration
- Affected code: serviceradar-agent status push loop, sweep status collection, agent-gateway status handling/logging
