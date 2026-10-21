## 1. Approval and specification

- [x] 1.1 Trace aggregate edge suppression and identify the existing deferred contract.
- [x] 1.2 Define exact relation semantics, compatibility, resource bounds and validation owners.
- [x] 1.3 Obtain approval for this extension before changing runtime behavior (approved in this conversation).
- [x] 1.4 Update the pending bitmap query proposal's partial-aggregate rule and design together with the implementation.

## 2. Implementation

- [x] 2.1 Add a failing synthetic regression for matching connections hidden by partial aggregates.
- [x] 2.2 Implement bounded native relation projection through the existing selection and query owners, with explicit whole-view work accounting.
- [x] 2.3 Add negotiated SRMO v2 edge columns and atomic server/client validation; preserve v1 bytes and behavior.
- [x] 2.4 Use exact counts for edge rendering and filtered picking; preserve full-bundle telemetry guards and query-scoped details.
- [x] 2.5 Keep retained node/edge membership together through camera changes and expiry.

## 3. Verification and delivery

- [x] 3.1 Demonstrate native correctness and bounded work on dense/sparse invented populations.
- [x] 3.2 Pass real-WebGPU zoom, false-connection, query-change, compatibility and partial-traffic cases.
- [x] 3.3 Update protocol documentation and validate OpenSpec strictly.
- [x] 3.4 Run applicable remote tests, lint, formatting and `make test`; inspect actual results (424 passed; two Apple-only targets skipped on Linux).
- [ ] 3.5 Commit the implementation in the Treehouse worktree and drive no-mistakes through PR and green CI.
