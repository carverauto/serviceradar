## ADDED Requirements

### Requirement: Add-on systemd units self-heal
When an add-on is assigned and enabled for an agent, the agent SHALL reconcile the desired-vs-actual state of the add-on's systemd units on each delivery/heartbeat: if the `.service`/`.timer` unit is missing or inactive while the binary is staged, the agent SHALL re-install, enable, and start the unit (with backoff, touching only add-on-owned units), rather than treating a staged binary as "installed".

#### Scenario: Staged binary but missing unit
- **WHEN** an enabled add-on's binary is staged on the host but its systemd `.timer`/`.service` unit is absent or inactive
- **THEN** the agent re-installs and enables the unit so the add-on resumes running, and logs a reconciliation warning

### Requirement: Per-agent enablement is actually delivered
An enabled add-on configuration for an agent SHALL be delivered to that agent (reflected by a non-zero delivery count / non-null last-delivered timestamp) and applied to the on-host runtime profile, so that enabling an add-on in the control plane results in `runtime.json` reflecting `enabled:true`.

#### Scenario: Enable does not reach the agent
- **WHEN** an agent's add-on config is set to enabled but the on-host runtime profile remains `enabled:false` with `delivery_count = 0`
- **THEN** this is treated as a delivery failure to be remediated, not a steady state

### Requirement: Add-on fleet inventory reporting
The system SHALL expose a fleet view reporting, per agent and per add-on: the assigned version, the published content hash/digest, approval status, assignment status, running/active state, last-delivered timestamp, and last status-report timestamp (and last scan time for collector add-ons).

#### Scenario: Operator inspects add-on fleet state
- **WHEN** an operator opens the add-on fleet view
- **THEN** they can see which agents run which add-on at which version/hash and which are disabled, undelivered, or version-drifted
