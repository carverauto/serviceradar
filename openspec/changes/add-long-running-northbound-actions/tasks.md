## 1. Data Model

- [ ] 1.1 Extend invocation/target state to represent deferred, polling, result-fetching, completed, failed, expired, and canceled states.
- [ ] 1.2 Persist external correlation ID, next poll time, poll attempt count, deadline, and encrypted/redacted continuation state per target.
- [ ] 1.3 Add migration tests for platform-schema objects only.

## 2. Runtime and Dispatch

- [ ] 2.1 Extend Wasm action results with an accepted/deferred response shape.
- [ ] 2.2 Add a poll/resume action entrypoint that receives original target context and continuation state.
- [ ] 2.3 Schedule polling through database-backed jobs with uniqueness per invocation target.
- [ ] 2.4 Enforce descriptor timeout, maximum duration, retry/backoff, and cancellation semantics.
- [ ] 2.5 Persist final results and normalized failure details after the external task completes.

## 3. SDK and Example Plugin

- [ ] 3.1 Update `serviceradar-sdk-go` with deferred result, poll request, and final result helpers.
- [ ] 3.2 Update the sample northbound Wasm plugin to model launch, poll, and result fetch against an imaginary asynchronous API.
- [ ] 3.3 Add fixture payloads for launch response, poll request, poll-in-progress response, and final-result response.

## 4. UI and Operators

- [ ] 4.1 Update Task History to show deferred/polling/result-fetch progress clearly.
- [ ] 4.2 Refresh device/interface history after launch and while visible without blocking LiveView events.
- [ ] 4.3 Document where users find results after launching a task.

## 5. Validation

- [ ] 5.1 Add unit tests for state transitions, continuation redaction, poll scheduling, and expiration.
- [ ] 5.2 Add Wasm runtime tests for immediate and deferred action results.
- [ ] 5.3 Add LiveView tests for long-running action status visibility.
- [ ] 5.4 Run `openspec validate add-long-running-northbound-actions --strict`.
