# ansible-automation Specification

## Purpose
Define the deployed agent control-stream bridge that executes core-issued AWX verbs through the AWX WASM plugin and returns launch/pulse results. Target identity, inventory partitioning, and delegated callback authorization remain governed by separate active changes.
## Requirements
### Requirement: The agent executes AWX command verbs via the awx plugin
The agent SHALL route `awx.*` command verbs to the awx WASM plugin and return its
result, so core-issued AWX REST verbs (launch/list/fetch/cancel) execute.

#### Scenario: Launch a job template against a host
- **GIVEN** a registered AWX controller bound to an agent that hosts the awx plugin
- **AND** a launchable Playbook backed by an AWX job template
- **AND** a device that is a member of the controller's AWX inventory
- **WHEN** an operator launches the playbook against that device
- **THEN** the agent invokes the awx plugin's `awx.launch_job` verb
- **AND** AWX launches the job
- **AND** the PlaybookRun advances to `launching` with an `awx_job_id`
- **AND** run pulse populates plays/tasks until a terminal state
