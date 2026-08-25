defmodule ServiceRadar.Inventory.Interface do
  @moduledoc """
  Network interface resource for discovered interfaces.

  Maps to `platform.discovered_interfaces`, which stores current interface
  state: one row per `(device_id, interface_uid)`, upserted. `timestamp` is
  last observed, not part of the identity.

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

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @devices_view_check {ActorHasPermission, permission: "devices.view"}
  @devices_update_check {ActorHasPermission, permission: "devices.update"}
  @devices_delete_check {ActorHasPermission, permission: "devices.delete"}
  @interface_fields [
    :timestamp,
    :device_id,
    :interface_uid,
    :agent_id,
    :gateway_id,
    :device_ip,
    :if_index,
    :if_name,
    :if_descr,
    :if_alias,
    :if_speed,
    :speed_bps,
    :if_phys_address,
    :ip_addresses,
    :if_admin_status,
    :if_oper_status,
    :if_type,
    :if_type_name,
    :interface_kind,
    :classifications,
    :classification_meta,
    :classification_source,
    :mtu,
    :duplex,
    :metadata,
    :available_metrics,
    :partition,
    :created_at
  ]
  @device_fields [:device_id]

  postgres do
    table "discovered_interfaces"
    repo ServiceRadar.Repo
    schema "platform"
  end

  json_api do
    type "interface"

    # Composite primary key: use delimiter-based encoding
    primary_key do
      keys [:device_id, :interface_uid]
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
    define :get_by_device_and_uid, action: :by_device_and_uid, args: [:device_id, :interface_uid]
    define :list_by_gateway, action: :by_gateway, args: [:gateway_id]
  end

  actions do
    defaults [:read]

    create :create do
      accept @interface_fields

      change fn changeset, _context ->
        case Ash.Changeset.fetch_change(changeset, :ip_addresses) do
          {:ok, addresses} when is_list(addresses) ->
            Ash.Changeset.change_attribute(
              changeset,
              :ip_addresses,
              ServiceRadar.Inventory.Interface.canonical_ip_addresses(addresses)
            )

          _ ->
            changeset
        end
      end
    end

    update :reassign_device do
      description "Reassign interface records to a new device (used during merges)"
      accept @device_fields
    end

    destroy :destroy do
      description "Delete interface records (used during device merges)"
    end

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

    read :by_device_and_uid do
      description "Get a specific interface by device and interface UID"
      argument :device_id, :string, allow_nil?: false
      argument :interface_uid, :string, allow_nil?: false
      get? true
      filter expr(device_id == ^arg(:device_id) and interface_uid == ^arg(:interface_uid))
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
    import ServiceRadar.Policies

    # System actors can perform all operations (schema isolation via search_path)
    system_bypass()

    action_type_with_permission(:create, @devices_update_check)

    # Read access for authenticated users
    read_with_permission(@devices_view_check)

    action_type_with_permission(:update, @devices_update_check)

    action_type_with_permission(:destroy, @devices_delete_check)
  end

  attributes do
    # Last-observed. Identity is (device_id, interface_uid); putting timestamp
    # on the Ash primary key is the append-only mechanism GitHub #4021 removes.
    # Ash bulk update/destroy identify rows by this key, so it must match
    # Postgres PRIMARY KEY (device_id, interface_uid).
    attribute :timestamp, :utc_datetime do
      allow_nil? false
      public? true
      description "When interface was last observed"
    end

    attribute :device_id, :string do
      allow_nil? false
      primary_key? true
      public? true
      description "Device unique identifier"
    end

    attribute :interface_uid, :string do
      allow_nil? false
      primary_key? true
      public? true
      description "Interface unique identifier (ifindex or name-based)"
    end

    attribute :if_index, :integer do
      allow_nil? true
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

    attribute :partition, :string do
      default "default"
      public? true
      description "Discovery partition"
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
      description "Interface speed in bits per second (legacy)"
    end

    attribute :speed_bps, :integer do
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

    attribute :if_type, :integer do
      public? true
      description "Interface type identifier (ifType)"
    end

    attribute :if_type_name, :string do
      public? true
      description "Interface type name (human-readable)"
    end

    attribute :interface_kind, :string do
      public? true
      description "Interface classification (physical, virtual, loopback, tunnel, etc.)"
    end

    attribute :classifications, {:array, :string} do
      default []
      public? true
      description "Interface classification tags (management, wan, vpn, etc.)"
    end

    attribute :classification_meta, :map do
      default %{}
      public? true
      description "Classification metadata (matched rules, etc.)"
    end

    attribute :classification_source, :string do
      default "rules"
      public? true
      description "Classification source (rules, manual, etc.)"
    end

    attribute :mtu, :integer do
      public? true
      description "Interface MTU"
    end

    attribute :duplex, :string do
      public? true
      description "Interface duplex mode"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    attribute :available_metrics, {:array, :map} do
      default nil
      public? true
      description "Available SNMP metrics for this interface (discovered during SNMP walk)"
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

  @doc """
  Canonical order for an interface's addresses: most useful first, then
  deduplicated and sorted for stability.

  Two reasons, and the second is the one that costs money.

  `primary_ip` is defined as `ip_addresses[1]`, so the array's order IS a
  semantic. Today that order is whatever the collector happened to serialise:
  one real interface produced **12 distinct textual values for 3 distinct
  address sets**, nine of them pure permutations. `primary_ip` therefore
  already changes between polls at random -- ordering here does not break a
  working thing, it makes a broken one deterministic, and makes "primary" mean
  the most reachable address rather than the luckiest one.

  Those permutations also make every stored row byte-distinct, which is half of
  why `discovered_interfaces` holds ~98 rows per interface state: nothing can
  tell a real change from a reshuffle. Sorting must happen on WRITE -- a reader
  cannot un-write rows that already exist, and the comparison that decides
  whether to write happens first.

  Ranking is `Identity.Address`, the same one that decides a device's primary
  IP, so an interface and its device agree about what a useful address is.
  """
  @spec canonical_ip_addresses(term()) :: [String.t()]
  def canonical_ip_addresses(addresses) when is_list(addresses) do
    addresses
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort_by(&{-ServiceRadar.Inventory.Identity.Address.rank(&1), &1})
  end

  def canonical_ip_addresses(_addresses), do: []

  identities do
    # Current-state identity. :timestamp is last-observed, not part of the key
    # -- including it is what made every poll insert. GitHub #4021.
    identity :unique_interface, [:device_id, :interface_uid]
  end
end
