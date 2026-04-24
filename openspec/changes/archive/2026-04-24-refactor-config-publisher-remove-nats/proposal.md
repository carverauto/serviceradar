# Change: Refactor ConfigPublisher to use Phoenix PubSub instead of NATS

**Status: Proposed** (2026-01-12)

## Why
The `ConfigPublisher` module currently uses NATS to broadcast cache invalidation messages between core/gateway nodes. This is unnecessary complexity - Elixir applications in the same cluster can use ERTS (Erlang Runtime System) distributed messaging or Phoenix PubSub for inter-node communication without requiring an external messaging system.

NATS is appropriate for:
- Communication with non-Elixir services (Go agents, datasvc)
- Cross-cluster communication
- Message persistence (JetStream)

NATS is NOT needed for:
- Elixir-to-Elixir communication within a cluster
- Ephemeral cache invalidation signals

## What Changes
- Replace NATS publishing in `ConfigPublisher` with Phoenix PubSub broadcasts
- Use `Phoenix.PubSub.broadcast/3` for cluster-wide cache invalidation
- Remove NATS connection dependency from ConfigPublisher
- Simplify the invalidation flow to use Erlang's built-in distribution

## Impact
- Affected specs: agent-config (new spec for config delivery system)
- Affected code:
  - `serviceradar_core/lib/serviceradar/agent_config/config_publisher.ex` (refactor to PubSub)
  - `serviceradar_core/lib/serviceradar/agent_config/config_server.ex` (subscribe to PubSub)
  - Remove unused NATS subjects for config invalidation
