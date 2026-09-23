## ADDED Requirements

### Requirement: Frames carry the identity a client needs to detect change
Every data frame delivered to a dashboard package SHALL carry enough identity for a
client to tell a refreshed frame from the one it already holds, without inspecting
row data. Specifically each frame that carries its own freshly-run rows SHALL carry
`refreshed_at` (when those rows were produced) and `content_hash` (derived from the
rows or payload), and every delivered frame SHALL carry `checked_at` (when the host
last evaluated the query, whether or not the result changed).

#### Scenario: A refreshed frame is distinguishable from its predecessor
- **GIVEN** a dashboard with a `json_rows` frame whose row values have changed since the last delivery, while its row count, id, encoding, status and query are unchanged
- **WHEN** the host re-runs the frame and delivers it
- **THEN** the delivered frame SHALL carry a `refreshed_at` later than the previous delivery's, and a `content_hash` different from the previous delivery's
- **AND** a client comparing only frame metadata SHALL conclude the frame changed

#### Scenario: An unchanged frame is still reported as checked
- **GIVEN** a dashboard frame whose query returns identical results on consecutive evaluations
- **WHEN** the host re-evaluates it
- **THEN** the client SHALL learn that the data was checked, via a `checked_at` later than the previous one
- **AND** `refreshed_at` SHALL NOT advance, because the data did not change

#### Scenario: Preserved stale rows are not reported as fresh
- **GIVEN** a frame whose re-run failed, and for which the host preserves the previous successful rows rather than showing nothing
- **WHEN** that frame is delivered
- **THEN** it SHALL carry forward the `refreshed_at` of the rows it actually contains, not the time of the failed attempt
- **AND** it SHALL carry a `checked_at` reflecting the failed attempt
- **AND** a client SHALL therefore be able to render the true age of the data it is showing

#### Scenario: Change detection does not depend on row data
- **GIVEN** a frame carrying a large `arrow_ipc` payload
- **WHEN** a client decides whether to re-decode it
- **THEN** the decision SHALL be possible from frame metadata alone
- **AND** the client SHALL NOT be required to decode or hash the payload to detect a change

### Requirement: Adding freshness metadata does not amplify delivery
Timestamp and identity fields added to a frame SHALL NOT cause the host to deliver
frames it would otherwise have suppressed. The host's decision to push SHALL be
based on whether the data changed, not on whether a timestamp advanced.

#### Scenario: An unchanged frame is not re-pushed every tick
- **GIVEN** a dashboard whose frames' data is unchanged across several refresh ticks
- **WHEN** those ticks occur
- **THEN** the host SHALL NOT push a full frame replacement for them
- **AND** it SHALL NOT re-send any associated binary payloads
- **AND** any liveness signal it sends instead SHALL NOT carry frame rows

#### Scenario: A changed frame is still pushed promptly
- **GIVEN** the same dashboard, whose frame data then changes
- **WHEN** the next refresh tick evaluates it
- **THEN** the host SHALL deliver the updated frame

### Requirement: A request the host cannot service reports failure
When a dashboard package asks the host to refresh or page a frame and the host
cannot act on the request, the host SHALL reply with an error identifying why. It
SHALL NOT reply with success having done nothing.

#### Scenario: Paging while a refresh is in flight
- **GIVEN** a dashboard package requesting the next page of a frame at a moment when the host is already running a refresh
- **WHEN** the request is received
- **THEN** the host SHALL either service the request or reply with an error
- **AND** it SHALL NOT reply with success while discarding the request

#### Scenario: Forcing a refresh does not destroy paging position
- **GIVEN** a dashboard package that has paged a frame away from its first page
- **WHEN** the package requests a refresh
- **THEN** the frame's paging position SHALL be preserved
- **AND** the request SHALL either be serviced or reported as failed

#### Scenario: Declaring more frames than the host will run is reported
- **GIVEN** a dashboard manifest declaring more data frames than the host is willing to evaluate concurrently
- **WHEN** the dashboard is loaded
- **THEN** the frames the host declines to run SHALL be reported to the renderer as errored frames
- **AND** they SHALL NOT be silently omitted from the delivered set

### Requirement: Cursor direction is honoured
When a dashboard package pages a frame, the host SHALL honour the direction of the
request, so that requesting the previous page returns the previous page.

#### Scenario: Paging backward returns the previous page
- **GIVEN** a dashboard package that has advanced a frame to its second page
- **WHEN** it requests the previous page
- **THEN** the host SHALL deliver the first page
- **AND** it SHALL NOT deliver the third page or repeat the second
