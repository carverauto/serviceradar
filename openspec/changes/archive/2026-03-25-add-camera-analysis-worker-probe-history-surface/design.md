## Context
The platform already has:
- worker registry
- active worker probing
- worker health/failover telemetry
- operator-facing worker management

What is missing is a bounded operator-facing history of probe outcomes.

## Goals
- Persist or maintain a bounded recent probe history per worker.
- Expose recent probe outcomes through the existing management API and UI.
- Keep the history bounded so probe observability does not create unbounded storage growth.

## Non-Goals
- Full time-series analytics for every probe forever
- A separate probe analytics subsystem
- Replacing telemetry; this complements telemetry with operator-friendly recent context

## Approach
1. Add bounded recent probe fields to the worker registry model.
2. Update the active probe manager to append the latest probe outcome.
3. Return recent probe history through the existing worker API response.
4. Render recent probe outcomes in the worker management LiveView.

## Bounded History
- Keep a small fixed-size recent probe list per worker, newest first.
- Each item should include:
  - timestamp
  - status
  - normalized reason when failed

## Risks
- Updating probe history on every probe can increase write frequency.
- The history structure must stay small and predictable.
