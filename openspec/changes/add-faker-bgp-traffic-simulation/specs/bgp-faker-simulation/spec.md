## ADDED Requirements
### Requirement: Faker SHALL Support BGP Simulation Profiles
The `serviceradar-faker` service SHALL support a configurable BGP simulation mode with profile-driven peers, prefixes, and timing controls.

#### Scenario: Load FRR-aligned demo profile
- **GIVEN** faker starts with the demo BGP profile enabled
- **WHEN** configuration is loaded
- **THEN** faker SHALL initialize local ASN `401642`
- **AND** it SHALL load IPv4 and IPv6 peer sets and advertised prefixes from profile configuration

### Requirement: Faker SHALL Generate Route Lifecycle Changes Through BGP
When BGP simulation mode is enabled, faker SHALL apply route lifecycle changes covering announcements and withdrawals for both IPv4 and IPv6 prefixes through a BGP daemon that exports BMP to Arancini.

#### Scenario: Steady-state advertisements
- **GIVEN** simulation mode is enabled with steady-state scenario
- **WHEN** the scheduler runs
- **THEN** faker SHALL apply route announcements for configured IPv4 and IPv6 prefixes through BGP
- **AND** resulting BMP records SHALL include peer identity context

#### Scenario: Withdrawal cycle
- **GIVEN** simulation mode is enabled with withdrawal cycles
- **WHEN** a withdrawal phase begins
- **THEN** faker SHALL apply withdraw operations for selected active prefixes through BGP
- **AND** subsequent re-advertisement cycles SHALL restore those prefixes

### Requirement: Faker SHALL Simulate Peer Outages
The simulator SHALL support peer-down and peer-recovery events to model causal state transitions.

#### Scenario: Randomized peer outage window
- **GIVEN** outage simulation is enabled with a configured interval and duration range
- **WHEN** an outage window is selected
- **THEN** faker SHALL force peer-down state for selected peers
- **AND** it SHALL restore corresponding peer-up state after the outage duration

### Requirement: Simulation SHALL Be Opt-In in Demo/Dev Deployment
BGP simulation SHALL be disabled by default and only enabled via explicit deployment configuration.

#### Scenario: Default faker mode remains unchanged
- **GIVEN** faker starts without BGP simulation enabled
- **WHEN** service initialization completes
- **THEN** faker SHALL continue existing Armis emulation behavior
- **AND** no BGP simulation BMP traffic SHALL be produced

#### Scenario: Demo deployment enables simulation
- **GIVEN** demo deployment sets BGP simulation enablement flags
- **WHEN** faker starts in demo
- **THEN** faker SHALL begin emitting configured BGP simulation scenarios
- **AND** operators SHALL be able to tune rates and outage behavior through config
