## Context

The current northbound action path assumes a plugin invocation returns the final action result in one request/response. That works for simple APIs but not for asynchronous NCM/NMS systems where launch, status, and result retrieval are separate API calls.

## Goals

- Support vendor APIs that return an external task/job ID before work has completed.
- Keep initial action dispatch bounded by descriptor timeout and agent runtime budgets.
- Persist enough continuation state to survive service or agent restarts.
- Make progress visible in the same Action History surface used for immediate actions.
- Let plugin authors own vendor-specific polling and result parsing logic.

## Non-Goals

- Implement OpenText Network Automation as part of this proposal.
- Add a generic HTTP workflow engine or arbitrary multi-step visual workflow builder.
- Keep long-running external jobs alive inside an agent process without persisted state.

## Proposed Model

An action invocation can produce either an immediate final result or a deferred result:

- `final`: the existing success/failure result shape.
- `deferred`: includes external correlation ID, next poll delay, optional deadline, and opaque plugin continuation state.
- `poll`: control-plane scheduled work re-dispatches the plugin with continuation state and target context.
- `result fetch`: the plugin may report completed status and final result in the same poll response, or request one more result-fetch phase if the vendor API separates status and output retrieval.

Continuation state should be encrypted/redacted according to the existing action input/result policy because it may contain vendor task IDs, URLs, or cursors.

## Open Questions

- Whether polling should run on the same agent that launched the task or any eligible agent assigned to the provider.
- Whether the continuation state belongs on `ActionInvocation`, `ActionInvocationTarget`, or a dedicated child resource when one invocation targets many devices.
- How to bound retry/backoff separately from vendor-reported still-running status.
