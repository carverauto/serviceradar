## ADDED Requirements

### Requirement: Cluster-wide cache invalidation via Phoenix PubSub
The ConfigPublisher module SHALL use Phoenix PubSub for broadcasting cache invalidation events to other nodes in the Elixir cluster, instead of NATS.

#### Scenario: Local cache invalidation
- **GIVEN** a resource change triggers config invalidation
- **WHEN** `ConfigPublisher.publish_invalidation/3` is called
- **THEN** the local ConfigServer cache is invalidated immediately

#### Scenario: Cluster-wide cache invalidation
- **GIVEN** multiple Elixir nodes are connected via ERTS
- **WHEN** `ConfigPublisher.publish_invalidation/3` is called on one node
- **THEN** all other nodes receive the PubSub broadcast and invalidate their caches

#### Scenario: No NATS dependency for config invalidation
- **GIVEN** the ConfigPublisher module
- **WHEN** broadcasting cache invalidation events
- **THEN** NATS SHALL NOT be used for Elixir-to-Elixir cluster communication
