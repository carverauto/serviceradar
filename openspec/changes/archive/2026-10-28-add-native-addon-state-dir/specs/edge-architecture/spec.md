## ADDED Requirements

### Requirement: Native add-on state directory
The agent SHALL create a persistent per-add-on state directory for every native
sidecar add-on it supervises, located beside the add-on's versioned artifacts
(`<agent runtime root>/addons/<addon_id>/state`), and SHALL pass its path to the
add-on process as `SERVICERADAR_ADDON_STATE_DIR`. The directory SHALL be private
to the user the add-on runs as and SHALL survive artifact upgrades, rollbacks,
add-on restarts and agent restarts. An add-on that keeps re-warm state SHALL
default that state into the directory so no operator configuration is required
for a restart to re-warm.

#### Scenario: Add-on receives its state directory at spawn
- **WHEN** the agent spawns a native sidecar add-on
- **THEN** the state directory SHALL exist with mode `0700` before the add-on's first `configure()`
- **AND** the add-on process environment SHALL contain `SERVICERADAR_ADDON_STATE_DIR` pointing at it

#### Scenario: Artifact upgrade keeps the state
- **GIVEN** an add-on has written state into its state directory
- **WHEN** the agent stages a new artifact version and flips the `current` symlink
- **THEN** the state directory and its contents SHALL be unchanged
- **AND** the restarted add-on SHALL receive the same directory path

#### Scenario: Anomaly add-on checkpoints without operator configuration
- **GIVEN** an anomaly add-on assignment whose params do not set `checkpoint_path`
- **WHEN** the add-on is launched with `SERVICERADAR_ADDON_STATE_DIR`
- **THEN** it SHALL persist its checkpoint as `checkpoint.json` inside that directory
- **AND** an explicit `checkpoint_path` param SHALL take precedence when present

#### Scenario: Host cannot provide the directory
- **WHEN** the agent cannot create the state directory
- **THEN** it SHALL log the failure and launch the add-on without the variable
- **AND** the add-on SHALL run as before, cold-starting on restart
