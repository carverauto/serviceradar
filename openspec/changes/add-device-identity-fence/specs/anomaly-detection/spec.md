## ADDED Requirements

### Requirement: Episodes survive a device identity transition
The pipeline SHALL keep one logical anomaly represented as one episode across a device
identity transition, and SHALL NOT report a condition as resolved merely because the device
it was observed on was merged away.

Two identities are involved and they behave differently. The **edge** identity is derived
locally on the agent (hostname, polled target IP, or agent id) and does not change when a
device is merged, so `episode_uid` is stable across a merge. The **core** identity is
re-resolved on ingest to the canonical device, so `device_uid`, `series_key` and
`finding_uid` all change at the moment of a merge.

An episode row SHALL therefore be updated in place on a merge, and its device-derived fields
SHALL be kept mutually consistent: leaving `finding_uid` at its pre-merge value while
`device_uid` and `series_key` are rewritten makes the row unmatchable by finding identity and
causes a later duplicate episode.

#### Scenario: An open episode is re-attributed in place, not duplicated
- **GIVEN** an open anomaly episode attributed to device A
- **WHEN** A is merged into device B and the next report arrives from the unchanged edge identity
- **THEN** the same episode row is updated
- **AND** its device attribution is B
- **AND** its opened-at timestamp is unchanged
- **AND** no second episode row is created

#### Scenario: Device-derived episode fields stay mutually consistent
- **GIVEN** an episode whose device attribution changes because of a merge
- **WHEN** the episode row is updated
- **THEN** its finding identity, series key and device attribution all reflect the canonical
  device
- **AND** none of them retains a pre-merge value

#### Scenario: An edge-side episode restart after a merge folds onto the open episode
- **GIVEN** an episode that was re-attributed by a merge and is still open
- **WHEN** the edge starts a new episode for the same series, after a checkpoint expiry or an
  agent restart, and reports under a new episode identity
- **THEN** the report folds onto the existing open episode by finding identity
- **AND** no duplicate episode is created
- **AND** the original episode is not later closed as stale

#### Scenario: Findings recorded before a re-key remain joinable
- **GIVEN** finding rows written under an episode's pre-merge finding identity
- **WHEN** the episode's finding identity is rewritten because of a merge
- **THEN** the previous and current finding identities are recorded
- **AND** the earlier rows can still be associated with the episode

#### Scenario: Closed episodes on a merged-away device are re-attributed
- **GIVEN** closed historical episodes attributed to device A
- **WHEN** A is merged into device B
- **THEN** those episodes are attributed to B
- **AND** no episode continues to reference a device that no longer exists

### Requirement: Episode identity granularity is explicit
The pipeline SHALL take an explicit position on whether an episode is scoped per series or
per series per detector, because core recomputes finding identity from the canonical device
and collapses detector-specific edge identities into it. Where two detectors report on one
series, the pipeline SHALL NOT silently fold one detector's episode onto another's unless
that is the intended scope.

#### Scenario: Two detectors on one series resolve to the declared scope
- **GIVEN** a drift report and a spike report for the same series
- **WHEN** both are ingested
- **THEN** they produce one episode if episode scope is per series
- **AND** they produce separate episodes if episode scope is per series per detector
- **AND** the outcome matches the declared scope rather than depending on arrival order
