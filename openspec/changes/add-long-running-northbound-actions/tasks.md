## 1. Data Model

- [x] 1.1 Extend invocation/target state to represent deferred, polling, result-fetching, completed, failed, expired, and canceled states.
- [x] 1.2 Persist external correlation ID, next poll time, poll attempt count, deadline, and encrypted/redacted continuation state per target.
- [x] 1.3 Add migration tests for platform-schema objects only.

## 2. Runtime and Dispatch

- [x] 2.1 Extend Wasm action results with an accepted/deferred response shape.
- [x] 2.2 Add a poll/resume action entrypoint that receives original target context and continuation state.
- [x] 2.3 Schedule polling through database-backed jobs with uniqueness per invocation target.
- [x] 2.4 Enforce descriptor timeout, maximum duration, retry/backoff, and cancellation semantics.
- [x] 2.5 Persist final results and normalized failure details after the external task completes.
- [x] 2.6 Add per-target webhook callback metadata and token-gated callback result handling.

## 3. SDK and Example Plugin

- [x] 3.1 Update `serviceradar-sdk-go` with deferred result, poll request, and final result helpers.
- [x] 3.2 Update the sample northbound Wasm plugin to model launch, poll, and result fetch against an imaginary asynchronous API.
- [x] 3.3 Add fixture payloads for launch response, poll request, poll-in-progress response, and final-result response.
- [x] 3.4 Update `serviceradar-sdk-go` and the sample plugin with callback metadata and webhook-only deferred mode.

## 4. UI and Operators

- [x] 4.1 Update Action History to show deferred/polling/result-fetch progress clearly.
- [x] 4.2 Refresh device/interface history after launch and while visible without blocking LiveView events.
- [x] 4.3 Document where users find results after launching a task.

## 5. Validation

- [x] 5.1 Add unit tests for state transitions, continuation redaction, poll scheduling, and expiration.
- [x] 5.2 Add Wasm runtime tests for immediate and deferred action results.
- [x] 5.3 Add LiveView tests for long-running action status visibility.
- [x] 5.4 Run `openspec validate add-long-running-northbound-actions --strict`.
