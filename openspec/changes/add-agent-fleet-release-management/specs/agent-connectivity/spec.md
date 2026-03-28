## ADDED Requirements

### Requirement: Desired-version reconciliation on reconnect
After an agent completes `Hello` and establishes its control stream, the control plane SHALL compare the agent's reported current version against any stored desired version or active rollout target. If the agent is eligible for an update, the gateway SHALL deliver the update instruction without waiting for the next config poll.

#### Scenario: Reconnected agent resumes pending rollout
- **GIVEN** an agent has a pending rollout target for version `v1.2.3`
- **AND** the agent was offline when the rollout began
- **WHEN** the agent reconnects, completes `Hello`, and reports current version `v1.2.2`
- **THEN** the control plane reconciles the pending target
- **AND** the gateway delivers the update instruction over the control stream if the rollout batch is currently eligible

#### Scenario: No update when agent already matches desired version
- **GIVEN** an agent reconnects and reports current version `v1.2.3`
- **AND** the stored desired version for that agent is `v1.2.3`
- **WHEN** version reconciliation runs
- **THEN** no update instruction is sent
- **AND** the agent remains compliant with the desired state
