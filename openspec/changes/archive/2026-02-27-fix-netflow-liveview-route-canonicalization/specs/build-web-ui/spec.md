## ADDED Requirements
### Requirement: NetFlow visualize route canonicalization
The web-ng UI SHALL treat `/flows` as the canonical route for `ServiceRadarWebNGWeb.NetflowLive.Visualize`. All in-page NetFlow navigation generated from that LiveView (including `push_patch`, SRQL builder submit/apply paths, pagination links, and table links) MUST resolve to `/flows` so patches stay within the active root view.

#### Scenario: NetFlow chart/state updates patch within the active LiveView
- **GIVEN** an authenticated user is on the NetFlow visualize page
- **WHEN** they change visualize state, run a query, or paginate results
- **THEN** the LiveView patches to a `/flows` URL
- **AND** the session does not raise a `cannot push_patch/2` root-view mismatch

#### Scenario: Legacy netflow aliases are removed
- **GIVEN** a user opens `/netflow` or `/netflows`
- **WHEN** the request is handled
- **THEN** the application does not serve a NetFlow LiveView at those paths
- **AND** NetFlow visualization is available only at `/flows`
