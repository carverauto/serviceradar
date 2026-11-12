## ADDED Requirements

### Requirement: Flow Pipeline Declares No Events-Stream Residual Drains

The flow EventWriter pipeline SHALL consume only subjects owned by the
dedicated `flows` stream and SHALL NOT declare residual-drain consumers
against the shared `events` stream. `Config.load_flow/0` MUST NOT emit any
stream entry with `best_effort: true` or a name ending in `_EVENTS_DRAIN`,
and no supported environment variable re-enables such entries.

#### Scenario: Flow load emits live consumers only

- **GIVEN** default flow configuration
- **WHEN** `Config.load_flow/0` builds the flow pipeline streams
- **THEN** every entry targets the `flows` stream
- **AND** no entry carries `best_effort: true`
- **AND** no entry name ends in `_EVENTS_DRAIN`

#### Scenario: No kill-switch resurrects drains

- **GIVEN** `EVENT_WRITER_FLOW_DRAIN_EVENTS` set or unset to any value
- **WHEN** `Config.load_flow/0` builds the flow pipeline streams
- **THEN** the variable has no effect on the emitted entries
