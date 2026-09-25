## ADDED Requirements

### Requirement: OTel service catalog maintenance
The system SHALL maintain a catalog of OTel services (`service.name`) that have reported logs, traces or metrics, recording for each service the last time each signal was seen. EventWriter updates the catalog as a best-effort, throttled side effect of persisting a batch, on both the CNPG and the StarRocks write paths.

A catalog update failure MUST NOT fail, nack or retry the telemetry batch that triggered it. Empty service names and names longer than 255 characters SHALL NOT be recorded. Entries not seen within the configured retention window (default 30 days) SHALL be pruned.

#### Scenario: A new service appears after its first batch
- **GIVEN** no catalog entry exists for `checkout`
- **WHEN** EventWriter persists a trace batch containing spans with `service_name = checkout`
- **THEN** the catalog SHALL contain `checkout` with `traces_last_seen_at` set, within the configured refresh interval

#### Scenario: Catalog is maintained when logs are stored in StarRocks
- **GIVEN** StarRocks is enabled and logs are written to the warehouse
- **WHEN** EventWriter persists a log batch for `billing`
- **THEN** the catalog SHALL record `billing` with `logs_last_seen_at` set
- **AND** no log rows SHALL be written to CNPG

#### Scenario: Catalog write failure does not affect telemetry
- **GIVEN** the catalog upsert fails
- **WHEN** EventWriter processes a metrics batch
- **THEN** the metrics batch SHALL be persisted and acknowledged normally
- **AND** an upsert-error telemetry event SHALL be emitted

#### Scenario: Repeated batches do not rewrite the catalog
- **GIVEN** `checkout` was recorded for traces on this node within the refresh interval
- **WHEN** another trace batch for `checkout` persists
- **THEN** EventWriter SHALL NOT issue a catalog write for that service and signal

#### Scenario: Stale services are pruned
- **GIVEN** a catalog entry whose `last_seen_at` is older than the retention window
- **WHEN** the daily prune job runs
- **THEN** the entry SHALL be removed

### Requirement: Service catalog cardinality guard
The system SHALL stop adding new services to the catalog once it holds the configured maximum number of entries (default 50,000), while continuing to refresh existing entries and continuing to persist all telemetry. It SHALL emit the catalog size as a metric and log a warning when the cap is reached.

#### Scenario: Cap reached
- **GIVEN** the catalog holds the maximum number of entries
- **WHEN** a batch reports a service name not in the catalog
- **THEN** the telemetry SHALL be persisted
- **AND** the new name SHALL NOT be inserted into the catalog
- **AND** existing catalog entries in the batch SHALL still have their last-seen refreshed

### Requirement: Service filter on observability panes
The logs, traces and metrics panes SHALL each provide a service filter control that opens a searchable service picker backed by the service catalog. The picker SHALL search on the server, SHALL return at most a bounded number of results per query (default 50) together with the total match count, and SHALL NOT load the full catalog into the page.

The picker SHALL list only services that have reported the current pane's signal. It SHALL support selecting multiple services (up to 20) and SHALL offer a free-text option when the search matches no catalog entry. No catalog query SHALL run during the disconnected mount.

#### Scenario: Searching thousands of services
- **GIVEN** the catalog holds 5,000 services that reported logs
- **WHEN** the user opens the service picker on the logs pane and types `pay`
- **THEN** the picker SHALL show at most 50 matching services
- **AND** it SHALL show the total number of matches
- **AND** the search SHALL be evaluated by the server, not by filtering a preloaded list

#### Scenario: Picker is scoped to the pane's signal
- **GIVEN** `batch-exporter` has reported metrics but never traces
- **WHEN** the user opens the service picker on the traces pane
- **THEN** `batch-exporter` SHALL NOT be listed

#### Scenario: Free-text fallback
- **WHEN** the user types a service name that matches no catalog entry
- **THEN** the picker SHALL offer to filter by the typed value anyway

### Requirement: Service filter merges into the pane query
Applying a service selection SHALL replace only the pane's service filter in its SRQL query, keeping every other filter, the time range and the sort. It SHALL also reset pagination and be reflected in the URL.

Clearing the selection SHALL remove the service filter. The active service filter SHALL be carried into the target pane when the user switches between the logs, traces and metrics panes. A service name shown in a list row SHALL apply a single-service filter when clicked.

#### Scenario: Existing filters survive a service selection
- **GIVEN** the logs pane query is `in:logs time:last_1h severity_text:error`
- **WHEN** the user selects `checkout` and `billing` in the service picker
- **THEN** the query SHALL be `in:logs time:last_1h severity_text:error service_name:("checkout","billing")` (token order may differ)
- **AND** the list SHALL reload from the first page

#### Scenario: Changing the selection replaces the previous service filter
- **GIVEN** the pane query contains `service_name:"checkout"`
- **WHEN** the user selects only `billing`
- **THEN** the query SHALL contain `service_name:"billing"` and no `checkout` service filter

#### Scenario: Service filter follows a tab switch
- **GIVEN** the logs pane is filtered to `service_name:"checkout"`
- **WHEN** the user opens the traces pane
- **THEN** the traces query SHALL include the `checkout` service filter

#### Scenario: Clicking a row's service
- **WHEN** the user clicks the service name `checkout` on a trace row
- **THEN** the traces pane SHALL re-query filtered to `checkout`

### Requirement: Stat cards honor the service filter
When a service filter is active on the logs, traces or metrics pane, the pane's stat cards SHALL be scoped to the selected services. A card whose backing rollup cannot be narrowed by service SHALL be visibly labelled as covering all services rather than presenting unscoped numbers as if they matched the filtered list.

#### Scenario: Log severity cards scoped to a service
- **GIVEN** the logs pane is filtered to `service_name:"checkout"`
- **WHEN** the severity cards render
- **THEN** their counts SHALL cover only `checkout` logs

#### Scenario: A card that cannot be scoped says so
- **GIVEN** a service filter is active
- **AND** a card's backing rollup does not support a service filter
- **WHEN** the card renders
- **THEN** it SHALL display an "all services" indicator

### Requirement: Service picker authorization
Every service picker event SHALL re-check that the current user may view the pane's signal before querying the catalog.

#### Scenario: User without trace access
- **GIVEN** a user without `observability.traces.view`
- **WHEN** a `service_picker` event is sent for the traces pane
- **THEN** the event SHALL be rejected and no catalog query SHALL run
