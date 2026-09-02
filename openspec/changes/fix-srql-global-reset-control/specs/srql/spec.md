## ADDED Requirements

### Requirement: Global SRQL reset restores the route baseline
The shared SRQL query bar reset control SHALL restore the current page to the same
canonical SRQL query used on first navigation to that route when `q` is absent. Reset
MUST be a distinct intent from Run / `srql_submit`. An empty Run SHALL continue to keep
the current query. Reset MUST NOT clear the input to a blank string, MUST NOT
hard-code a NetFlows-only query in the shared component, and MUST NOT leave the
visible input, URL-backed `q`, cursor/page state, or rendered results disagreeing
with each other.

#### Scenario: Reset is a single effective click
- **GIVEN** the SRQL query bar is showing a non-baseline query
- **WHEN** the user clicks the reset control once
- **THEN** the input updates to the route baseline
- **AND** the URL `q` parameter updates to that same baseline (or is omitted only when
  that is already how first visit encodes the baseline **and** no client hook rehydrates
  a previous filter)
- **AND** cursor and page state are cleared so results load from the head of the
  baseline query
- **AND** the rendered result set matches the baseline query

#### Scenario: Network Flows chart range is cleared
- **GIVEN** the user is on `/observability/netflows` with a query that includes an
  explicit `time:[start,end]` window
- **WHEN** the user clicks the reset control
- **THEN** the query becomes the same baseline `handle_params` uses on first visit
  (currently `in:flows time:last_1h sort:time:desc`)
- **AND** the `time:[start,end]` token is gone
- **AND** results reload for that baseline

#### Scenario: Devices reset uses the devices first-visit default
- **GIVEN** the user is on the devices list with extra filters in `q`
- **WHEN** the user clicks the reset control
- **THEN** the query becomes the devices list first-visit default (`in:devices` plus
  that route's default sort/limit tokens)
- **AND** the page does not navigate to a different entity route

#### Scenario: Device detail reset stays on the device
- **GIVEN** the user is on a device detail page whose baseline query includes `uid:"…"`
- **WHEN** the user clicks the reset control
- **THEN** the query returns to that device-scoped baseline
- **AND** the LiveView does not navigate to `/devices`

#### Scenario: Remembered time window cannot resurrect after reset
- **GIVEN** `srql_time` holds a previously selected range
- **WHEN** the user clicks the reset control
- **THEN** that cookie is expired or replaced with the baseline window
- **AND** the query bar does not upsert the remembered range back into the input

#### Scenario: Run and builder controls still work
- **GIVEN** the query bar is visible
- **WHEN** the user clicks Run, toggles the builder, or applies builder changes
- **THEN** those controls behave as they did before this change
- **AND** an empty Run keeps the current query instead of resetting
