## ADDED Requirements

### Requirement: MTR Network Pathing Analytics Dashboard
The web UI SHALL provide a network pathing analytics dashboard that uses `in:mtr_hops stats:` SRQL queries to surface hop-level packet loss and latency aggregates, enabling operators to identify shared-path network problems across a device fleet.

The dashboard SHALL include: a highest-loss router addresses panel, a highest-latency router addresses panel, and an ASN-grouped loss panel for shared-path analysis. Each panel SHALL support a time-window selector (minimum: last 1h, 6h, 24h, 7d). Panels SHALL link hop addresses to filtered hop detail views.

Loss panels SHALL use `stats:loss_ratio(sent, received) by <dimension>` and latency panels SHALL use `stats:wavg(avg_us, received) by <dimension>`. `avg(loss_pct)` and `avg(avg_us)` are NOT acceptable here: averaging a percentage is a mean of ratios where loss is a ratio of sums, and an unweighted latency mean treats a value derived from one returned packet as equal to one derived from a hundred. The two computations disagree whenever the hops in a group sent unequal probe counts, which is the normal case, and an AS-level figure derived from a mean of ratios cannot support the shared-path attribution the scenarios below require. Those aggregates and the dashboard's statistical-correctness requirements are owned by `add-mtr-path-analytics`.

#### Scenario: Loss hotspot panel shows highest-loss routers
- **WHEN** an operator loads the analytics dashboard with time window last_24h
- **THEN** the loss hotspot panel displays router addresses ranked by packet loss descending
- **AND** each row shows the address and its loss percentage computed over summed probe counts

#### Scenario: ASN panel identifies shared-path issues
- **WHEN** multiple devices share a common upstream router or AS
- **THEN** the ASN-grouped panel surfaces the shared ASN with its average loss
- **AND** the panel distinguishes shared-path loss (high AS-level loss over summed probe counts) from device-specific loss (low AS-level loss, high per-device hop loss)

#### Scenario: Time window selector filters panel data
- **WHEN** an operator changes the time window from last_24h to last_7d
- **THEN** all panels reload with aggregates computed over the new window

#### Scenario: Empty data renders informative state
- **WHEN** no MTR hops exist for the selected time window
- **THEN** each panel renders an empty-state message rather than an error or blank space
