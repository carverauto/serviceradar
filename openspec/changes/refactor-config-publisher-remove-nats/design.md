## Context
The ConfigPublisher module broadcasts cache invalidation events when Ash resources affecting agent configs change. Currently it:
1. Invalidates local cache via `ConfigServer.invalidate/2`
2. Publishes to NATS for cluster-wide invalidation

This adds unnecessary dependency on NATS for Elixir-to-Elixir communication.

## Goals / Non-Goals
- Goals:
  - Remove NATS dependency from config cache invalidation
  - Use Elixir-native cluster communication (Phoenix PubSub / ERTS)
  - Maintain same invalidation semantics (local + cluster-wide)
- Non-Goals:
  - Changing how agents fetch configs (still via gRPC)
  - Changing what triggers invalidation (still Ash resource changes)
  - Adding new caching features

## Decisions
- **Use Phoenix PubSub**: Already available in the stack, handles cluster distribution automatically when nodes are connected via ERTS.
- **Topic naming**: Use `"config:invalidated"` as the PubSub topic
- **Message format**: Keep simple - `{:config_invalidated, tenant_id, config_type, opts}`

## Current Flow (NATS)
```
Resource Change → ConfigPublisher.publish_invalidation()
                     ├── ConfigServer.invalidate() (local)
                     └── NATS.publish() → Other nodes subscribe → invalidate()
```

## New Flow (PubSub)
```
Resource Change → ConfigPublisher.publish_invalidation()
                     ├── ConfigServer.invalidate() (local)
                     └── PubSub.broadcast() → All nodes receive → invalidate()
```

## Implementation

### ConfigPublisher changes
```elixir
# Before
defp publish_to_nats(subject, payload) do
  ServiceRadar.NATS.Connection.publish(subject, Jason.encode!(payload))
end

# After
defp broadcast_invalidation(tenant_id, config_type, opts) do
  Phoenix.PubSub.broadcast(
    ServiceRadar.PubSub,
    "config:invalidated",
    {:config_invalidated, tenant_id, config_type, opts}
  )
end
```

### ConfigServer subscription
```elixir
def init(state) do
  Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "config:invalidated")
  {:ok, state}
end

def handle_info({:config_invalidated, tenant_id, config_type, _opts}, state) do
  # Only invalidate if not from self (local already handled)
  invalidate_cache(tenant_id, config_type)
  {:noreply, state}
end
```

## Risks / Trade-offs
- **Risk**: PubSub requires ERTS cluster connectivity
  - Mitigation: This is already required for distributed Elixir apps
- **Trade-off**: Loses NATS message persistence
  - Acceptable: Cache invalidation is ephemeral; missed messages just mean slightly stale cache until next poll

## Migration Plan
1. Add PubSub subscription to ConfigServer
2. Update ConfigPublisher to broadcast via PubSub
3. Remove NATS publishing code
4. Test in staging with multi-node deployment

## Open Questions
- None
