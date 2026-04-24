# Change: Add agent command bus and push-config control channel

## Why
Operators need true on-demand execution (e.g., run discovery or a sweep immediately) without waiting on config polling. The current config-poll loop is too slow for “run now,” and there is no generic mechanism to trigger agent capabilities with feedback.

## What Changes
- Add a long-lived control stream between agent and agent-gateway to support immediate config pushes and command delivery.
- Introduce a generic command bus that can trigger agent capabilities on demand (discovery runs, sweep runs, etc.) with ack/progress/result feedback.
- Return immediate errors when an agent is offline (no queued delivery), and surface command status to the UI.
- Persist agent commands with an AshStateMachine lifecycle (queued → sent → acknowledged/running → completed/failed/offline/expired/canceled) and retain command history for 2 days.

## Impact
- Affected specs: `agent-connectivity`, `network-discovery`, `sweep-jobs`.
- Affected code: agent ↔ gateway gRPC protocol, gateway command routing, agent command execution, UI run-now actions + status feedback, new core persistence + cleanup for command history.
