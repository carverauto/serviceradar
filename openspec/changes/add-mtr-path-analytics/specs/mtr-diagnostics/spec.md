## ADDED Requirements

### Requirement: MTR path analytics panels use statistically sound aggregates

The MTR path analytics dashboard SHALL compute packet loss as a ratio of summed probe counts and hop latency as a received-weighted mean, and SHALL NOT present a mean of per-hop percentages or an unweighted mean of per-hop latencies as a group's loss or latency.

Loss panels SHALL use `loss_ratio(sent, received)` and latency panels SHALL use `wavg(avg_us, received)`. A group with no probes sent SHALL render as "no data" rather than as zero loss, because zero loss and no measurement are different operational states.

This requirement exists because the two computations disagree whenever the hops in a group sent unequal probe counts, which is the normal case, and because an AS-level loss figure derived from a mean of ratios cannot support distinguishing shared-path loss from device-specific loss.

#### Scenario: Unequal probe counts do not distort a group's loss
- **GIVEN** an address whose hops sent widely differing probe counts within the window
- **WHEN** an operator loads the loss panel
- **THEN** the address's loss reflects total lost probes over total sent probes
- **AND** a single low-sample hop with total loss does not dominate the figure

#### Scenario: No probes sent renders as no data
- **GIVEN** an address with no probes sent in the selected window
- **WHEN** an operator loads the loss panel
- **THEN** the row renders as "no data"
- **AND** it is not shown as zero percent loss

#### Scenario: ASN panel supports shared-path attribution
- **GIVEN** several devices traversing a common upstream autonomous system
- **WHEN** an operator loads the ASN panel
- **THEN** the shared autonomous system's loss is computed over summed probe counts across those devices
- **AND** that figure can be compared against per-device hop loss to attribute the problem to the shared path or to a device

### Requirement: MTR path analytics provides a loss trend over time

The MTR path analytics dashboard SHALL provide a panel showing loss over time within the selected window, grouped by a time bucket, so an operator can distinguish a sustained path problem from a transient one.

The trend panel SHALL use the `time:<duration>` stats group dimension and SHALL render buckets in ascending time order.

#### Scenario: Trend distinguishes sustained from transient loss
- **GIVEN** an address with elevated loss confined to one hour of a 24-hour window
- **WHEN** an operator loads the trend panel
- **THEN** the elevated loss appears in that hour's bucket only
- **AND** the remaining buckets show the unaffected loss level

#### Scenario: Empty window renders an informative state
- **WHEN** no MTR hops exist in the selected window
- **THEN** the trend panel renders an empty-state message rather than an error or blank space

### Requirement: MTR path analytics ships as a built-in dashboard definition backed by live queries

The product SHALL ship the MTR path analytics dashboard as a public authored dashboard definition available to every installation, without requiring an operator to import a dashboard package.

Only the definition ships: the dashboard record and its panels, each panel holding SRQL text. Every panel SHALL execute its query against live data each time the dashboard is loaded. No panel content is precomputed, captured when the definition is created, or stored alongside it.

Creating the definition SHALL be idempotent and SHALL NOT duplicate it or disturb any other built-in dashboard. The dashboard SHALL NOT introduce a new application route, and SHALL NOT require a dashboard SDK renderer artifact.

#### Scenario: Dashboard is present on a fresh installation
- **WHEN** a fresh installation finishes starting
- **THEN** the MTR path analytics dashboard is listed in the dashboard library
- **AND** an operator can open it without importing anything

#### Scenario: Panels reflect current data on every load
- **GIVEN** the dashboard definition was created earlier
- **WHEN** MTR hops are recorded after that point and an operator loads the dashboard
- **THEN** every panel reflects the newly recorded hops
- **AND** no panel serves a value captured when the definition was created

#### Scenario: Repeated application does not duplicate
- **GIVEN** the dashboard definition already exists
- **WHEN** the definition step runs again
- **THEN** exactly one MTR path analytics dashboard exists
- **AND** other built-in dashboards are unchanged

### Requirement: Operator edits to a built-in dashboard survive restarts

The product SHALL preserve operator modifications to a built-in dashboard definition, and SHALL NOT write a shipped panel query, title, or description back over an edited one when the definition step runs again.

An operator SHALL be able to adopt a built-in dashboard as their own: change a panel's SRQL to scope it to chosen devices, add or duplicate panels, and copy the dashboard. A definition step that restores shipped values over operator edits is prohibited. The divergence such a step creates surfaces only after a restart, long after the edit appeared to succeed, which is what makes it worse than refusing the edit outright.

A dashboard record that exists with no panels at all MAY have its shipped panels created, since that is an incomplete definition rather than an operator choice.

#### Scenario: An edited panel query is not reverted
- **GIVEN** an operator narrowed a built-in dashboard panel's SRQL to a chosen set of devices
- **WHEN** the service restarts and the definition step runs
- **THEN** the panel still carries the operator's query
- **AND** the shipped query is not written back over it

#### Scenario: An added panel is not removed
- **GIVEN** an operator added a panel to a built-in dashboard
- **WHEN** the definition step runs again
- **THEN** the added panel remains

#### Scenario: An incomplete definition is completed
- **GIVEN** a built-in dashboard record exists with no panels because creation was interrupted
- **WHEN** the definition step runs again
- **THEN** its shipped panels are created

### Requirement: Changing a dashboard's SRQL requires dashboard edit authority

The product SHALL permit only an actor holding dashboard edit authority to change the SRQL query a dashboard or system report is built on, and SHALL refuse the change for an actor who can merely view the dashboard.

Edit authority means the `analytics.dashboards.edit` permission or an explicit per-dashboard edit grant. Authorization SHALL be enforced at the data layer so it applies to every path that reaches the record, and SHALL fail closed when no rule matches. A built-in dashboard is public and has no owner, so view access SHALL NOT imply edit access for it.

Every interactive path that edits a panel SHALL supply the acting user as the actor, since a policy that is never given an actor does not run.

#### Scenario: A viewer cannot rewrite a built-in dashboard's query
- **GIVEN** an actor holding dashboard view permission but neither edit permission nor an edit grant
- **WHEN** that actor attempts to change a panel's SRQL on the public built-in MTR dashboard
- **THEN** the change is refused
- **AND** the stored query is unchanged

#### Scenario: An editor can scope the query to chosen devices
- **GIVEN** an actor holding `analytics.dashboards.edit`
- **WHEN** that actor narrows a panel's SRQL to a chosen set of devices
- **THEN** the change is saved
- **AND** subsequent loads run the narrowed query

#### Scenario: A per-dashboard grant is sufficient without the global permission
- **GIVEN** an actor without `analytics.dashboards.edit` who holds an edit grant on that dashboard
- **WHEN** that actor changes a panel's SRQL
- **THEN** the change is saved
