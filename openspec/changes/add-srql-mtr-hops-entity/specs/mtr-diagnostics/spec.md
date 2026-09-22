## ADDED Requirements

### Requirement: MTR Network Pathing Analytics Dashboard
The web UI SHALL provide a network pathing analytics dashboard that uses `in:mtr_hops stats:` SRQL queries to surface hop-level packet loss and latency aggregates, enabling operators to identify shared-path network problems across a device fleet.

The dashboard SHALL include: a highest-loss router addresses panel (`stats:avg(loss_pct) by addr`), a highest-latency router addresses panel (`stats:avg(avg_us) by addr`), and an ASN-grouped loss panel for shared-path analysis (`stats:avg(loss_pct) by asn`). Each panel SHALL support a time-window selector (minimum: last 1h, 6h, 24h, 7d). Panels SHALL link hop addresses to filtered hop detail views.

#### Scenario: Loss hotspot panel shows highest-loss routers
- **WHEN** an operator loads the analytics dashboard with time window last_24h
- **THEN** the loss hotspot panel displays router addresses ranked by average packet loss descending
- **AND** each row shows the address and average loss percentage

#### Scenario: ASN panel identifies shared-path issues
- **WHEN** multiple devices share a common upstream router or AS
- **THEN** the ASN-grouped panel surfaces the shared ASN with its average loss
- **AND** the panel distinguishes shared-path loss (high AS-level avg) from device-specific loss (low AS-level avg, high per-device hop loss)

#### Scenario: Time window selector filters panel data
- **WHEN** an operator changes the time window from last_24h to last_7d
- **THEN** all panels reload with aggregates computed over the new window

#### Scenario: Empty data renders informative state
- **WHEN** no MTR hops exist for the selected time window
- **THEN** each panel renders an empty-state message rather than an error or blank space
