## ADDED Requirements

### Requirement: Agent Host Identity Is Modeled
The DIRE resolution model SHALL have an agent observation report its agent id and its device's eligible MACs, and SHALL check the goal properties for an agent on a known host, same-named hosts at two sites, and an agent on a source-authoritative device.
The model's eligible MACs are its globally-unique MACs (`MacsOf(h) \cap HwIds`); every modeled
interface is a physical NIC. Goal configurations `resolution_goal_agent_known_host`,
`resolution_goal_agent_same_name` and `resolution_goal_agent_on_armis` check every goal property.
`resolution_vacuity_agent_links_known_host` expects `NeverAgentOnDiscoveredRecord` to fail, and
`resolution_vacuity_agent_on_source_record` expects `NeverAgentOnSourceRecord` to fail, so neither
the link nor the user-approved Armis join can pass vacuously. Golden traces
`agent_known_host_shared_mac` and `agent_same_name_two_sites` are recorded from the real code.

#### Scenario: The goal links an agent to its known host
- **GIVEN** the `agent_known_host` environment
- **WHEN** TLC checks `NeverAgentOnDiscoveredRecord`
- **THEN** it SHALL find a violation

#### Scenario: Same-named hosts never fuse in the model
- **GIVEN** the `agent_same_name` environment, two devices with one hostname, distinct integration ids, agents and MACs
- **WHEN** TLC checks the goal properties
- **THEN** `NoFalseMerge` SHALL hold

#### Scenario: Recorded traces match the model
- **GIVEN** the traces `agent_known_host_shared_mac` and `agent_same_name_two_sites` recorded from `AgentGatewaySync`, `SyncIngestor` and the census
- **WHEN** TLC checks each against `DireResolutionTrace`
- **THEN** each SHALL be matched to its last state
