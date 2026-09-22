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

### Requirement: MTR path analytics ships as a seeded built-in dashboard

The product SHALL ship the MTR path analytics dashboard as a seeded public authored dashboard available to every installation, without requiring an operator to import a dashboard package.

Seeding SHALL be idempotent: repeated application creates the dashboard once, reconciles drifted fields, and does not duplicate it or disturb other seeded dashboards. The dashboard SHALL NOT introduce a new application route, and SHALL NOT require a dashboard SDK renderer artifact.

#### Scenario: Dashboard is present on a fresh installation
- **WHEN** a fresh installation finishes starting
- **THEN** the MTR path analytics dashboard is listed in the dashboard library
- **AND** an operator can open it without importing anything

#### Scenario: Repeated seeding does not duplicate
- **GIVEN** the dashboard has already been seeded
- **WHEN** seeding runs again
- **THEN** exactly one MTR path analytics dashboard exists
- **AND** other seeded dashboards are unchanged
