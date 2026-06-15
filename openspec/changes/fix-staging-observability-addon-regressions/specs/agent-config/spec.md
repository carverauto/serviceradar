## ADDED Requirements

### Requirement: Idempotent config application on unchanged version
The agent SHALL treat a control-stream config push whose `ConfigVersion` equals the already-applied version as a no-op: it SHALL skip the full re-apply (sweep clear, sysmon, plugin assignments, netprobe re-attach) while still sending the `ConfigAck`. The core push path SHALL avoid re-pushing an unchanged config to an agent, and dependency-driven config fan-out SHALL be debounced/coalesced.

#### Scenario: Repeated identical config push
- **WHEN** the control stream pushes a config whose version equals the agent's currently-applied version
- **THEN** the agent does not re-run the apply pipeline, still acknowledges, and emits at most one "applied" log per genuine change

#### Scenario: Dependency reconcile burst
- **WHEN** a burst of add-on/plugin package writes occurs (e.g. a package reconcile flap)
- **THEN** the resulting config pushes to online agents are coalesced rather than fanned out per write
