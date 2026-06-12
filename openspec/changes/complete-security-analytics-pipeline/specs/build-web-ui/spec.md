## ADDED Requirements

### Requirement: Dashboard data frames execute concurrently

Dashboard package frames SHALL be evaluated concurrently with bounded
parallelism and per-frame timeouts, preserving result order and per-frame
error semantics, so a multi-frame dashboard's first paint is gated by the
slowest single frame rather than the sum of all frames. Non-primary frames
SHALL be deferrable (not required for first paint) and unchanged frames SHALL
be skipped on periodic refresh.

#### Scenario: Multi-frame dashboard paints in slowest-frame time
- **GIVEN** a dashboard with N data frames
- **WHEN** it loads
- **THEN** frames SHALL run concurrently and first paint SHALL block only on
  the required frames

#### Scenario: Unchanged frames not re-pushed
- **WHEN** a periodic refresh produces a frame identical to the last push
- **THEN** that frame SHALL NOT be re-pushed

### Requirement: Security page and security dashboard have distinct roles

The `/security` page SHALL be a triage/navigation shell (curated links and
selected-finding detail panels) and the `/dashboards/security-findings`
dashboard SHALL be the single declarative data surface; the two SHALL NOT
duplicate the same inline SRQL data queries.

#### Scenario: No duplicated data queries
- **WHEN** the security analytics surfaces are rendered
- **THEN** the bulk security data SHALL come from the dashboard package frames,
  and `/security` SHALL NOT re-issue the same per-source data probes inline
