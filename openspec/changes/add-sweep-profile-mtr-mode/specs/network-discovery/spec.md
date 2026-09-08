# network-discovery

## ADDED Requirements

### Requirement: MTR is a selectable scheduled sweep mode
A sweep profile SHALL support `mtr` as a scan mode alongside `icmp` and `tcp`,
and a scheduled sweep whose profile enables `mtr` SHALL run MTR through the
sweep engine on the profile's interval.

#### Scenario: Profile with MTR enabled
- **WHEN** an administrator enables `mtr` on a sweep profile and saves it
- **THEN** the compiled agent sweep config SHALL include `mtr` (and its
  options), and the agent SHALL run MTR against the profile's targets on its
  configured interval

#### Scenario: MTR runs in the same sweep pass as ICMP/TCP
- **WHEN** a sweep profile enables `icmp`, `tcp`, and `mtr`
- **THEN** the sweep engine SHALL execute all three modes for the target set in
  one sweep run, with MTR running under a bounded worker pool so it does not
  block the ICMP/TCP phases

### Requirement: Unified per-host sweep result covers MTR
The per-host sweep result SHALL carry MTR reachability alongside ICMP and TCP
results in a single aggregate, without a separate parallel result type.

#### Scenario: Mixed-mode host result
- **WHEN** a host is scanned with `icmp`, `tcp`, and `mtr` in one sweep
- **THEN** its host result SHALL contain the ICMP status, the TCP port results,
  and the MTR reachability status (reached, round-trip, hop count) together

#### Scenario: MTR contributes to availability
- **WHEN** MTR reaches a target during a sweep
- **THEN** the host SHALL be reflected as available in the sweep's up/down view

### Requirement: MTR reachability and full trace are both persisted
Scheduled-sweep MTR SHALL persist a reachability summary through the sweep
results pipeline and the full per-hop trace through the MTR results pipeline,
both traversing JetStream (never a direct database write from the agent).

#### Scenario: Reachability in the sweep view
- **WHEN** a scheduled sweep runs MTR against a target
- **THEN** the target's reachability SHALL appear in the sweep host results
  store

#### Scenario: Full trace retained
- **WHEN** a scheduled sweep runs MTR against a target
- **THEN** the full per-hop trace SHALL be retained in the MTR traces store for
  that target

### Requirement: MTR sweep options are configurable per profile
A sweep profile SHALL allow configuring MTR options (protocol and maximum
hops), defaulting sensibly when unset.

#### Scenario: Default MTR options
- **WHEN** a profile enables `mtr` without specifying options
- **THEN** the sweep SHALL run MTR with default protocol (`icmp`) and a default
  maximum hop count

#### Scenario: Custom MTR options
- **WHEN** a profile sets an MTR protocol and maximum hops
- **THEN** the compiled config SHALL carry those options to the agent
