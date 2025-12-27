# ServiceRadar Core

Core business logic library for the ServiceRadar distributed monitoring platform.

## Overview

`serviceradar_core` is a shared Elixir library that contains:

- **Ash Domains**: Identity, Inventory, Infrastructure, Monitoring, Edge
- **Cluster Management**: libcluster + Horde for distributed process management
- **SPIFFE/SPIRE Integration**: mTLS certificate helpers for secure cluster communication
- **Telemetry**: Shared metrics and event definitions

This library is used as a dependency by:
- `serviceradar_web` (Phoenix web application)
- `serviceradar_poller` (Standalone edge poller)
- `serviceradar_agent` (Standalone monitoring agent)

## Installation

Add `serviceradar_core` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:serviceradar_core, path: "../elixir/serviceradar_core"}
    # or for published hex package:
    # {:serviceradar_core, "~> 0.1.0"}
  ]
end
```

## Configuration

### Database

```elixir
config :serviceradar_core, ServiceRadar.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "serviceradar_dev",
  pool_size: 10
```

### Cluster

```elixir
config :serviceradar_core,
  cluster_enabled: true

config :libcluster,
  topologies: [
    serviceradar: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"web@host1", :"poller@host2"]]
    ]
  ]
```

### SPIFFE/mTLS

```elixir
config :serviceradar_core, :spiffe,
  trust_domain: "serviceradar.local",
  cert_dir: "/etc/serviceradar/certs",
  mode: :filesystem  # or :workload_api for SPIRE
```

### Oban (Background Jobs)

```elixir
config :serviceradar_core, Oban,
  repo: ServiceRadar.Repo,
  queues: [default: 10, alerts: 5, sweeps: 20, edge: 10],
  plugins: [Oban.Plugins.Pruner]
```

## Ash Domains

### Identity

User management, authentication, and API tokens.

```elixir
# Create a user
ServiceRadar.Identity.User
|> Ash.Changeset.for_create(:create, %{email: "user@example.com", password: "secret"})
|> Ash.create!()
```

### Inventory

Partition and service inventory management.

### Infrastructure

Devices, pollers, and agents.

### Monitoring

Alerts, logs, and observability data.

### Edge

Edge onboarding, packages, and deployment.

## Cluster & Registry

### Poller Registration

```elixir
# Register a poller in the distributed registry
ServiceRadar.PollerRegistry.register(%{
  partition_id: "partition-1",
  poller_id: "poller-001",
  domain: "example.com",
  capabilities: [:icmp, :tcp, :http]
})

# Find pollers for a partition
ServiceRadar.PollerRegistry.find_by_partition("partition-1")
```

### Agent Registration

```elixir
# Register an agent
ServiceRadar.AgentRegistry.register(%{
  partition_id: "partition-1",
  poller_id: "poller-001",
  agent_id: "agent-001",
  capabilities: [:snmp, :wmi]
})
```

## SPIFFE Integration

```elixir
# Get SSL options for ERTS distribution
{:ok, ssl_opts} = ServiceRadar.SPIFFE.ssl_dist_opts()

# Build a SPIFFE ID
spiffe_id = ServiceRadar.SPIFFE.build_spiffe_id(:poller, "partition-1", "poller-001")
# => "spiffe://serviceradar.local/poller/partition-1/poller-001"

# Verify a peer's SPIFFE ID
{:ok, verified_id} = ServiceRadar.SPIFFE.verify_peer_id(peer_cert)
```

## Telemetry

```elixir
# Emit events
ServiceRadar.Telemetry.emit_cluster_event(:node_connected, %{node: :"poller@host1"})
ServiceRadar.Telemetry.emit_poller_event(:registered, %{partition_id: "p1", poller_id: "poller-001"})

# Get metrics definitions for Phoenix.LiveDashboard
metrics = ServiceRadar.Telemetry.metrics()

# Attach default handlers for logging
ServiceRadar.Telemetry.attach_default_handlers()
```

## Standalone Release Configuration

For standalone poller/agent releases, configure the cluster to join the main ServiceRadar cluster:

```elixir
# rel/env.sh.eex
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=poller@${HOSTNAME}

# Enable TLS distribution
export ERL_FLAGS="-proto_dist inet_tls -ssl_dist_optfile /etc/serviceradar/ssl_dist.conf"
```

### ssl_dist.conf

```erlang
[{server, [
  {certfile, "/etc/serviceradar/certs/svid.pem"},
  {keyfile, "/etc/serviceradar/certs/svid-key.pem"},
  {cacertfile, "/etc/serviceradar/certs/bundle.pem"},
  {verify, verify_peer},
  {fail_if_no_peer_cert, true}
]},
{client, [
  {certfile, "/etc/serviceradar/certs/svid.pem"},
  {keyfile, "/etc/serviceradar/certs/svid-key.pem"},
  {cacertfile, "/etc/serviceradar/certs/bundle.pem"},
  {verify, verify_peer}
]}].
```

## Migration from web-ng

The `web-ng` application has been refactored to use `serviceradar_core` as a shared library. Here's what changed:

### Repo Migration

The database repository has been moved from `ServiceRadarWebNG.Repo` to `ServiceRadar.Repo` in `serviceradar_core`. The old `ServiceRadarWebNG.Repo` module now delegates to `ServiceRadar.Repo` for backwards compatibility.

```elixir
# Old way (still works via delegation)
alias ServiceRadarWebNG.Repo
Repo.all(User)

# New way (preferred)
alias ServiceRadar.Repo
Repo.all(User)
```

### Configuration Changes

Database configuration should now use `:serviceradar_core`:

```elixir
# config/dev.exs
config :serviceradar_core, ServiceRadar.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "serviceradar_dev"
```

### Docker Changes

The Dockerfile now copies `elixir/serviceradar_core` before building `web-ng`:

```dockerfile
# Copy shared library first
COPY elixir/serviceradar_core ./elixir/serviceradar_core

# Then copy web-ng
COPY web-ng ./web-ng
```

### Testing

For tests using `Ecto.Adapters.SQL` directly (sandbox, raw queries), use `ServiceRadar.Repo`:

```elixir
# For sandbox operations
Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, :manual)

# For raw SQL queries
Ecto.Adapters.SQL.query!(ServiceRadar.Repo, "SELECT 1", [])
```

## Testing

```bash
# Run unit tests (no database required)
mix test --no-start

# Run integration tests (requires database)
mix ecto.create && mix ecto.migrate
mix test --include integration
```

## License

Apache-2.0
