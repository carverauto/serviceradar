---
sidebar_position: 11
title: Ash Migration Guide
---

# Migration Guide

This guide covers migrating existing ServiceRadar deployments to the Ash Framework architecture.

## Overview

ServiceRadar has transitioned from Ecto-based contexts to Ash Framework for:
- Domain-driven resource modeling
- Built-in authorization policies
- Multi-tenancy support
- JSON:API endpoints
- Background job scheduling

## Breaking Changes

### Authentication

**Before (Ecto):**
```elixir
Accounts.create_user(%{email: "user@example.com", password: "secret"})
Accounts.authenticate_user(email, password)
```

**After (Ash):**
```elixir
ServiceRadar.Identity.User
|> Ash.Changeset.for_create(:register_with_password, %{
  email: "user@example.com",
  password: "secret",
  password_confirmation: "secret"
})
|> Ash.create()

# Authentication is handled by AshAuthentication strategies
```

### Device Operations

**Before:**
```elixir
Inventory.get_device!(id)
Inventory.update_device(device, attrs)
```

**After:**
```elixir
ServiceRadar.Inventory.Device
|> Ash.Query.for_read(:by_id, %{id: id}, actor: actor)
|> Ash.read_one!()

device
|> Ash.Changeset.for_update(:update, attrs, actor: actor)
|> Ash.update()
```

### Gateway/Agent Operations

**Before:**
```elixir
Infrastructure.register_gateway(attrs)
Infrastructure.get_agents_for_gateway(gateway_id)
```

**After:**
```elixir
ServiceRadar.Infrastructure.Gateway
|> Ash.Changeset.for_create(:register, attrs, actor: system_actor)
|> Ash.create()

ServiceRadar.Infrastructure.Agent
|> Ash.Query.for_read(:by_gateway, %{gateway_id: gateway_id}, actor: actor)
|> Ash.read()
```

## Database Migrations

### Required Migrations

1. **Tenants table** - Multi-tenancy support
2. **tenant_id columns** - Added to all tenant-scoped tables
3. **User role column** - Role-based access control
4. **API tokens table** - Programmatic API access

Run migrations:
```bash
mix ash.migrate
```

### Data Migrations

After schema migrations, run data migrations to:
1. Create a default tenant for existing data
2. Assign existing users to the default tenant
3. Set default roles for existing users

```bash
mix run priv/repo/migrations/data/assign_default_tenant.exs
mix run priv/repo/migrations/data/assign_user_roles.exs
```

## API Changes

### JSON:API Endpoints

New versioned API at `/api/v2`:

| Old Endpoint | New Endpoint | Notes |
|--------------|--------------|-------|
| `GET /api/devices` | `GET /api/v2/devices` | JSON:API format |
| `GET /api/gateways` | `GET /api/v2/gateways` | JSON:API format |
| `GET /api/alerts` | `GET /api/v2/alerts` | JSON:API format |

### SRQL Queries

SRQL queries continue to work but now route through Ash:

```json
{
  "entity": "devices",
  "filters": {"is_available": true}
}
```

The SRQL adapter (`ServiceRadarWebNG.SRQL.AshAdapter`) translates queries to Ash operations.

## Configuration Changes

### Environment Variables

New required variables:

```bash
# Token signing secret (required)
TOKEN_SIGNING_SECRET=your-32-byte-secret-here

# PII encryption key (required for AshCloak)
CLOAK_KEY=base64-encoded-32-byte-key
# Or read the key from a file
CLOAK_KEY_FILE=/etc/serviceradar/cloak/cloak.key

# Optional: API rate limiting
API_RATE_LIMIT=1000  # requests per minute
```

### AshCloak Key Persistence and Validation

AshCloak encrypts sensitive fields at rest (tenant contact info, tenant CA private keys,
NATS account seeds, operator seeds). These encrypted values are stored in CNPG and can
only be decrypted with the same platform key. If the key changes or is lost, the data
becomes unreadable.

Key persistence by environment:

- Docker Compose: a `cloak-key` volume is created and seeded once. The key is stored at
  `/etc/serviceradar/cloak/cloak.key` and read via `CLOAK_KEY_FILE`.
  Set `CLOAK_KEY` in `.env` before first boot if you need a specific key.
- Helm/Kubernetes: store the key in the `serviceradar-secrets` Secret under `cloak-key`,
  or set `secrets.cloakKey` in `helm/serviceradar/values.yaml` to seed it.

Validation (detect wrong/missing key):

Run a read that decrypts at least one cloaked field. If the key is wrong, AshCloak will
raise a decryption error.

```bash
cd web-ng
# Ensure CNPG_* and CLOAK_KEY or CLOAK_KEY_FILE are set for this environment.
mix run -e 'alias ServiceRadar.Identity.Tenant; q = Tenant |> Ash.Query.for_read(:read); IO.inspect(Ash.read!(q, authorize?: false) |> Enum.take(1))'
```

If you see AshCloak decryption errors, the platform key does not match the key used
when the data was written.

### Application Configuration

Update `config/runtime.exs`:

```elixir
config :serviceradar_core,
  token_signing_secret: System.fetch_env!("TOKEN_SIGNING_SECRET"),
  ecto_repos: [ServiceRadar.Repo]

config :ash, :policies, show_policy_breakdowns?: true

# AshOban configuration
config :serviceradar_web_ng, Oban,
  repo: ServiceRadar.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron, crontab: []}
  ],
  queues: [
    default: 10,
    service_checks: 20,
    alert_escalation: 5,
    alert_notifications: 10,
    edge_packages: 5
  ]
```

## Context Module Updates

Existing context modules now delegate to Ash:

### ServiceRadarWebNG.Inventory

```elixir
defmodule ServiceRadarWebNG.Inventory do
  def list_devices(opts \\ []) do
    actor = Keyword.get(opts, :actor)

    ServiceRadar.Inventory.Device
    |> Ash.Query.for_read(:list, %{}, actor: actor)
    |> Ash.read()
  end
end
```

### ServiceRadarWebNG.Infrastructure

```elixir
defmodule ServiceRadarWebNG.Infrastructure do
  def list_gateways(opts \\ []) do
    actor = Keyword.get(opts, :actor)

    ServiceRadar.Infrastructure.Gateway
    |> Ash.Query.for_read(:list, %{}, actor: actor)
    |> Ash.read()
  end
end
```

## LiveView Updates

### Actor Context

LiveViews must pass the actor to Ash operations:

```elixir
def mount(_params, _session, socket) do
  actor = socket.assigns.current_scope.user
  tenant_id = actor.tenant_id

  {:ok, devices} =
    ServiceRadar.Inventory.Device
    |> Ash.Query.for_read(:list, %{}, actor: actor, tenant: tenant_id)
    |> Ash.read()

  {:ok, assign(socket, devices: devices)}
end
```

### Form Handling

For Ash-backed forms, use AshPhoenix:

```elixir
def handle_event("save", %{"device" => params}, socket) do
  case ServiceRadar.Inventory.Device
       |> Ash.Changeset.for_create(:create, params,
         actor: socket.assigns.current_scope.user)
       |> Ash.create() do
    {:ok, device} ->
      {:noreply, push_navigate(socket, to: ~p"/devices/#{device.id}")}
    {:error, changeset} ->
      {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

## Testing Updates

### Test Helpers

Import Ash test helpers:

```elixir
defmodule MyTest do
  use ServiceRadarWebNG.DataCase
  use ServiceRadarWebNG.AshTestHelpers

  test "creates device" do
    tenant = tenant_fixture()
    actor = admin_actor(tenant)

    {:ok, device} =
      ServiceRadar.Inventory.Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "test-device",
        hostname: "test.local",
        type_id: 1
      }, actor: actor, tenant: tenant.id)
      |> Ash.create()

    assert device.uid == "test-device"
  end
end
```

### Policy Testing

Test authorization policies:

```elixir
test "viewer cannot create devices" do
  tenant = tenant_fixture()
  viewer = viewer_actor(tenant)

  assert {:error, %Ash.Error.Forbidden{}} =
    ServiceRadar.Inventory.Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "test",
      hostname: "test.local",
      type_id: 1
    }, actor: viewer, tenant: tenant.id)
    |> Ash.create()
end
```

## Rollback Plan

If issues occur, you can temporarily revert to Ecto contexts:

1. Set feature flag: `ASH_ENABLED=false`
2. Context modules will use Ecto fallbacks
3. Monitor for issues
4. Re-enable Ash when stable

## Support

For migration assistance:
- Review [Ash Framework documentation](https://hexdocs.pm/ash/)
- Check [ServiceRadar Ash domains documentation](./ash-domains.md)
- File issues at https://github.com/carverauto/serviceradar/issues
