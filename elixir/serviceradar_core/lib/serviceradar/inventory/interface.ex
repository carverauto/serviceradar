defmodule ServiceRadar.Inventory.Interface do
  @moduledoc """
  Network interface resource for discovered interfaces.

  Maps to the `discovered_interfaces` TimescaleDB hypertable which stores
  interface discovery events. Each record represents an interface state
  at a specific point in time.

  ## OCSF Alignment

  Interface fields align with OCSF Network Interface object attributes:
  - `if_name` -> name
  - `if_index` -> uid (interface index)
  - `if_phys_address` -> mac
  - `ip_addresses` -> ip addresses array
  - `if_admin_status` -> admin state
  - `if_oper_status` -> operational state

  ## Admin/Oper Status Values

  - 1: up
  - 2: down
  - 3: testing
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "discovered_interfaces"
    repo ServiceRadar.Repo
  end

  json_api do
    type "interface"

    # Composite primary key: use delimiter-based encoding
    primary_key do
      keys [:timestamp, :device_id, :if_index]
      delimiter "~"
    end

    routes do
      base "/interfaces"

      index :read
    end
  end

  code_interface do
    define :list_by_device, action: :by_device, args: [:device_id]
    define :get_by_device_and_index, action: :by_device_and_index, args: [:device_id, :if_index]
    define :list_by_gateway, action: :by_gateway, args: [:gateway_id]
  end

  actions do
    defaults [:read]

    read :by_device do
      description "Get interfaces for a specific device"
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
    end

    read :by_device_and_index do
      description "Get a specific interface by device and index"
      argument :device_id, :string, allow_nil?: false
      argument :if_index, :integer, allow_nil?: false
      get? true
      filter expr(device_id == ^arg(:device_id) and if_index == ^arg(:if_index))
    end

    read :by_gateway do
      description "Get interfaces discovered by a specific gateway"
      argument :gateway_id, :string, allow_nil?: false
      filter expr(gateway_id == ^arg(:gateway_id))
    end

    read :latest do
      description "Get the most recent interface records"
      prepare build(sort: [timestamp: :desc], limit: 100)
    end

    read :active do
      description "Interfaces that are operationally up"
      filter expr(if_oper_status == 1)
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Read access: Authenticated users can read interfaces
    # Note: Full tenant isolation requires joining to device table
    # For now, allow reads for any authenticated user with a role
    policy action_type(:read) do
      authorize_if expr(^actor(:role) in [:viewer, :operator, :admin])
    end
  end

  # Note: discovered_interfaces doesn't have tenant_id yet
  # We'll use device_id relationship for tenant filtering

  attributes do
    # Composite primary key: timestamp + device_id + if_index
    attribute :timestamp, :utc_datetime do
      allow_nil? false
      primary_key? true
      public? true
      description "When interface was discovered/updated"
    end

    attribute :device_id, :string do
      allow_nil? false
      primary_key? true
      public? true
      description "Device unique identifier"
    end

    attribute :if_index, :integer do
      allow_nil? false
      primary_key? true
      public? true
      description "Interface index (SNMP ifIndex)"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent that discovered this interface"
    end

    attribute :gateway_id, :string do
      public? true
      description "Gateway that discovered this interface"
    end

    attribute :device_ip, :string do
      public? true
      description "Device IP address"
    end

    attribute :if_name, :string do
      public? true
      description "Interface name (e.g., eth0, GigabitEthernet0/1)"
    end

    attribute :if_descr, :string do
      public? true
      description "Interface description"
    end

    attribute :if_alias, :string do
      public? true
      description "Interface alias (user-configurable)"
    end

    attribute :if_speed, :integer do
      public? true
      description "Interface speed in bits per second"
    end

    attribute :if_phys_address, :string do
      public? true
      description "MAC address"
    end

    attribute :ip_addresses, {:array, :string} do
      default []
      public? true
      description "IP addresses assigned to interface"
    end

    attribute :if_admin_status, :integer do
      public? true
      description "Administrative status (1=up, 2=down, 3=testing)"
    end

    attribute :if_oper_status, :integer do
      public? true
      description "Operational status (1=up, 2=down, 3=testing)"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    attribute :created_at, :utc_datetime do
      public? true
      description "Record creation time"
    end
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_id
      destination_attribute :uid
      define_attribute? false
      allow_nil? false
      public? true
      description "Device this interface belongs to"
    end
  end

  calculations do
    calculate :admin_status_name,
              :string,
              expr(
                cond do
                  if_admin_status == 1 -> "up"
                  if_admin_status == 2 -> "down"
                  if_admin_status == 3 -> "testing"
                  true -> "unknown"
                end
              )

    calculate :oper_status_name,
              :string,
              expr(
                cond do
                  if_oper_status == 1 -> "up"
                  if_oper_status == 2 -> "down"
                  if_oper_status == 3 -> "testing"
                  true -> "unknown"
                end
              )

    calculate :status_color,
              :string,
              expr(
                cond do
                  if_oper_status == 1 and if_admin_status == 1 -> "green"
                  if_oper_status == 2 and if_admin_status == 1 -> "red"
                  if_admin_status == 2 -> "gray"
                  true -> "yellow"
                end
              )

    calculate :speed_formatted,
              :string,
              expr(
                cond do
                  is_nil(if_speed) ->
                    "Unknown"

                  if_speed >= 1_000_000_000_000 ->
                    fragment("? || ' Tbps'", if_speed / 1_000_000_000_000)

                  if_speed >= 1_000_000_000 ->
                    fragment("? || ' Gbps'", if_speed / 1_000_000_000)

                  if_speed >= 1_000_000 ->
                    fragment("? || ' Mbps'", if_speed / 1_000_000)

                  if_speed >= 1_000 ->
                    fragment("? || ' Kbps'", if_speed / 1_000)

                  true ->
                    fragment("? || ' bps'", if_speed)
                end
              )

    calculate :display_name,
              :string,
              expr(
                cond do
                  not is_nil(if_alias) and if_alias != "" -> if_alias
                  not is_nil(if_name) -> if_name
                  not is_nil(if_descr) -> if_descr
                  true -> fragment("'if' || ?", if_index)
                end
              )

    calculate :primary_ip, :string, expr(fragment("(?)[1]", ip_addresses))
  end
end
