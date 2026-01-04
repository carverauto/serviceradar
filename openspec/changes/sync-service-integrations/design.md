# Sync Service Integrations - Design

## Overview

This document describes the architecture for sync service onboarding and integration source management, including the elimination of KV store dependency for edge-deployed agents.

## Current Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────┐
│ IntegrationSource│────▶│ datasvc KV   │◀────│ Sync Service│
│ (Ash Resource)  │     │              │     │ (Go)        │
└─────────────────┘     └──────────────┘     └─────────────┘
                              │
                              ▼
                        ┌─────────────┐
                        │ Agent       │
                        │ (sweep.json)│
                        └─────────────┘
```

Problems:
1. Edge agents can't access KV (no network path)
2. Sync services appear implicitly, no onboarding
3. No way to select which sync processes an integration

## Proposed Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────┐
│ IntegrationSource│────▶│ SyncService  │◀────│ Sync Service│
│ (Ash Resource)  │     │ (Ash Resource)│     │ (Go)        │
└─────────────────┘     └──────────────┘     └─────────────┘
        │                      │                    │
        │                      │                    │
        ▼                      ▼                    ▼
┌─────────────────────────────────────────────────────────┐
│                        CNPG                              │
│  - integration_sources                                   │
│  - sync_services                                         │
│  - discovered_devices (NEW)                              │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │ AgentConfigGenerator│
                    │ (includes sweep)    │
                    └──────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │ GetConfig RPC    │
                    │ (agent receives) │
                    └──────────────────┘
```

## Key Components

### 1. SyncService Ash Resource

New resource to track onboarded sync services:

```elixir
defmodule ServiceRadar.Integrations.SyncService do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :service_type, :atom  # :saas, :on_prem
    attribute :endpoint, :string
    attribute :status, :atom  # :online, :offline, :degraded
    attribute :is_platform_sync, :boolean  # true for SaaS default
    attribute :capabilities, {:array, :string}  # ["armis", "netbox", "faker"]
    attribute :last_heartbeat_at, :utc_datetime
    attribute :tenant_id, :uuid
  end
end
```

### 2. DiscoveredDevice Ash Resource

Store device data from sync service in CNPG:

```elixir
defmodule ServiceRadar.Monitoring.DiscoveredDevice do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :device_id, :string  # external ID from source
    attribute :source_type, :atom  # :armis, :netbox, :faker
    attribute :ip_addresses, {:array, :string}
    attribute :mac_addresses, {:array, :string}
    attribute :hostname, :string
    attribute :device_type, :string
    attribute :manufacturer, :string
    attribute :model, :string
    attribute :os_info, :map
    attribute :raw_data, :map  # full payload from source
    attribute :first_seen_at, :utc_datetime
    attribute :last_seen_at, :utc_datetime
    attribute :agent_uid, :string  # which agent should monitor this
    attribute :integration_source_id, :uuid
    attribute :tenant_id, :uuid
  end
end
```

### 3. Platform Bootstrap Enhancement

At platform bootstrap, auto-create the SaaS sync service:

```elixir
defmodule ServiceRadar.Bootstrap do
  def ensure_platform_sync_service do
    case SyncService.get_platform_sync() do
      {:ok, _} -> :ok
      {:error, :not_found} ->
        SyncService.create_platform_sync(%{
          name: "ServiceRadar Cloud Sync",
          service_type: :saas,
          endpoint: "sync.serviceradar.cloud:443",
          is_platform_sync: true,
          capabilities: ["armis", "netbox", "faker"]
        })
    end
  end
end
```

### 4. Integration Source Enhancement

Add sync_service_id to IntegrationSource:

```elixir
# In IntegrationSource
attribute :sync_service_id, :uuid do
  description "Which sync service processes this integration"
end

relationships do
  belongs_to :sync_service, ServiceRadar.Integrations.SyncService
end
```

### 5. Sweep Config in GetConfig

Enhance AgentConfigGenerator to include sweep targets:

```elixir
defmodule ServiceRadar.Edge.AgentConfigGenerator do
  def generate_config(agent_id, tenant_id) do
    checks = load_agent_checks(agent_id, tenant_id)
    sweep_config = build_sweep_config(agent_id, tenant_id)

    %{
      checks: checks,
      sweep: sweep_config,
      # ... other config
    }
  end

  defp build_sweep_config(agent_id, tenant_id) do
    devices = DiscoveredDevice
      |> Ash.Query.filter(agent_uid == ^agent_id)
      |> Ash.read!(tenant: tenant_id)

    %{
      networks: extract_networks(devices),
      device_targets: build_device_targets(devices),
      sweep_modes: ["icmp", "tcp"]
    }
  end
end
```

## Data Flow

### Device Discovery Flow

1. User creates IntegrationSource with sync_service_id
2. Sync service polls integration (Armis/NetBox/Faker)
3. Sync service sends discovered devices to core via gRPC
4. Core stores devices in CNPG (DiscoveredDevice)
5. Agent calls GetConfig
6. AgentConfigGenerator builds sweep config from DiscoveredDevice
7. Agent receives sweep targets in config response

### Sync Service Onboarding Flow

1. **SaaS (automatic)**: Platform bootstrap creates SyncService record
2. **On-prem (manual)**:
   - Customer deploys sync service with mTLS creds
   - Sync service calls Hello RPC to register
   - Core creates SyncService record
   - Admin can view/manage in UI

## Proto Changes

Add messages for device sync:

```protobuf
message SyncDevicesRequest {
  string sync_service_id = 1;
  string tenant_id = 2;
  repeated DiscoveredDevice devices = 3;
}

message DiscoveredDevice {
  string device_id = 1;
  string source_type = 2;
  repeated string ip_addresses = 3;
  repeated string mac_addresses = 4;
  string hostname = 5;
  string device_type = 6;
  bytes raw_data = 7;
}

message SyncDevicesResponse {
  bool success = 1;
  int32 devices_processed = 2;
  int32 devices_created = 3;
  int32 devices_updated = 4;
}
```

Enhance AgentConfigResponse:

```protobuf
message AgentConfigResponse {
  // existing fields...
  SweepConfig sweep = 10;
}

message SweepConfig {
  repeated string networks = 1;
  repeated DeviceTarget device_targets = 2;
  repeated string sweep_modes = 3;
  int32 sweep_interval_sec = 4;
}

message DeviceTarget {
  string ip = 1;
  repeated int32 ports = 2;
  string hostname = 3;
}
```

## UI Changes

### Integration Sources Page

1. Show banner if no sync service is onboarded
2. Disable "Add Integration" button until sync available
3. Add sync service selector dropdown in integration form
4. Show which sync service is processing each integration

### Infrastructure Page (Platform Admin)

1. Add "Sync Services" tab
2. Show SaaS sync status
3. Allow adding on-prem sync services
4. Show sync service health/last heartbeat

## Migration Strategy

1. Create SyncService and DiscoveredDevice tables
2. Bootstrap SaaS sync service record
3. Migrate existing IntegrationSource records to reference SaaS sync
4. Deploy updated sync service with device push capability
5. Deploy updated agent with sweep-from-config support
6. Deprecate KV-based sweep.json (keep for backward compat)
7. Remove KV dependency in future release
