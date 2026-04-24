## Context
The AXIS camera plugin uses the shared Wasm agent runtime websocket capability to collect VAPIX events. The runtime already accepts a structured JSON websocket connect payload with explicit headers, but the plugin still uses the legacy URL-only helper and injects `username:password` into the websocket URL.

## Goals / Non-Goals
- Goals:
  - remove credential-bearing websocket URLs from the AXIS plugin event path
  - preserve current AXIS event collection behavior
  - keep the change local to the plugin and its tests
- Non-Goals:
  - redesign the generic agent websocket host functions
  - remove operator-configured camera auth from other plugin surfaces

## Decisions
- Decision: Use the existing structured websocket connect payload with explicit headers.
  - Alternatives considered:
    - keep URL userinfo and rely on operational hygiene: rejected because the safer transport path already exists
    - add a new runtime capability: rejected because the current runtime contract already supports headers

## Risks / Trade-offs
- AXIS devices may require a specific auth style for websocket upgrade requests.
  - Mitigation: preserve the existing auth mode semantics and cover the dial payload in tests.

## Migration Plan
1. Update the AXIS websocket connect helper to build a structured payload.
2. Send auth via headers rather than URL userinfo.
3. Add regression tests and update the review baseline disposition once implemented.
