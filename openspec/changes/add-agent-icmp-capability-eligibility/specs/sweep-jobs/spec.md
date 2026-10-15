## ADDED Requirements
### Requirement: Sweep Mode Eligibility by Agent Capability
The sweep compiler SHALL remove the `icmp` mode from every group it compiles for an agent that reports `icmp.unavailable`, and the `mtr` mode for an agent that reports `mtr.unavailable`.
A group left with no modes after this removal SHALL be omitted from that agent's compiled config, and core SHALL log a warning naming the group, the agent and the missing capability. An agent that reports neither the capability nor its unavailable marker SHALL receive every mode, as before.

#### Scenario: Ineligible agent keeps the TCP part of a mixed group
- **GIVEN** a sweep group with modes `["icmp", "tcp"]` and ports `[443]`
- **AND** an agent reporting `icmp.unavailable`
- **WHEN** the sweep config is compiled for that agent
- **THEN** the group SHALL be compiled with modes `["tcp"]`
- **AND** its device targets SHALL carry `sweep_modes` `["tcp"]`

#### Scenario: ICMP-only group is not sent to an ineligible agent
- **GIVEN** a sweep group with modes `["icmp"]`
- **AND** an agent reporting `icmp.unavailable`
- **WHEN** the sweep config is compiled for that agent
- **THEN** the compiled config SHALL NOT contain the group
- **AND** core SHALL log a warning naming the group, the agent and `icmp`

#### Scenario: Agent predating the capability
- **GIVEN** an agent whose capabilities contain neither `icmp` nor `icmp.unavailable`
- **WHEN** the sweep config is compiled for that agent
- **THEN** every group SHALL keep its `icmp` mode
