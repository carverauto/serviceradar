defmodule ServiceRadar.Inventory.Device do
  @moduledoc """
  Device resource for network inventory (OCSF v1.7.0 Device object).

  Maps to the `ocsf_devices` table with OCSF-aligned attributes.
  Devices can be discovered by pollers, agents, or external sources.

  ## OCSF Type IDs

  - 0: Unknown
  - 1: Server
  - 2: Desktop
  - 3: Laptop
  - 4: Tablet
  - 5: Mobile
  - 6: Virtual
  - 7: IOT
  - 8: Browser
  - 9: Firewall
  - 10: Switch
  - 11: Hub
  - 12: Router
  - 13: IDS
  - 14: IPS
  - 15: Load Balancer
  - 99: Other
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type "device"

    routes do
      base "/devices"

      get :by_uid
      index :read
    end
  end

  postgres do
    table "ocsf_devices"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    # OCSF Core Identity - uid is the primary key
    attribute :uid, :string do
      allow_nil? false
      primary_key? true
      public? true
      description "Unique device identifier"
    end

    attribute :type_id, :integer do
      default 0
      public? true
      description "OCSF device type ID"
    end

    attribute :type, :string do
      public? true
      description "OCSF device type name"
    end

    attribute :name, :string do
      public? true
      description "Device display name"
    end

    attribute :hostname, :string do
      public? true
      description "Device hostname"
    end

    attribute :ip, :string do
      public? true
      description "Primary IP address"
    end

    attribute :mac, :string do
      public? true
      description "Primary MAC address"
    end

    # OCSF Extended Identity
    attribute :uid_alt, :string do
      public? true
      description "Alternative unique identifier"
    end

    attribute :vendor_name, :string do
      public? true
      description "Device vendor/manufacturer"
    end

    attribute :model, :string do
      public? true
      description "Device model"
    end

    attribute :domain, :string do
      public? true
      description "Network domain"
    end

    attribute :zone, :string do
      public? true
      description "Network zone"
    end

    attribute :subnet_uid, :string do
      public? true
      description "Subnet identifier"
    end

    attribute :vlan_uid, :string do
      public? true
      description "VLAN identifier"
    end

    attribute :region, :string do
      public? true
      description "Geographic region"
    end

    # OCSF Temporal
    attribute :first_seen_time, :utc_datetime do
      public? true
      description "When device was first discovered"
    end

    attribute :last_seen_time, :utc_datetime do
      public? true
      description "When device was last seen"
    end

    attribute :created_time, :utc_datetime do
      public? true
      description "Record creation time"
    end

    attribute :modified_time, :utc_datetime do
      public? true
      description "Record modification time"
    end

    # OCSF Risk and Compliance
    attribute :risk_level_id, :integer do
      public? true
      description "OCSF risk level ID (0-4)"
    end

    attribute :risk_level, :string do
      public? true
      description "Risk level name"
    end

    attribute :risk_score, :integer do
      public? true
      description "Numeric risk score"
    end

    attribute :is_managed, :boolean do
      default false
      public? true
      description "Whether device is managed"
    end

    attribute :is_compliant, :boolean do
      public? true
      description "Compliance status"
    end

    attribute :is_trusted, :boolean do
      default false
      public? true
      description "Trust status"
    end

    # OCSF Nested Objects (JSONB)
    attribute :os, :map do
      default %{}
      public? true
      description "Operating system info (OCSF OS object)"
    end

    attribute :hw_info, :map do
      default %{}
      public? true
      description "Hardware info (OCSF Hardware Info object)"
    end

    attribute :network_interfaces, {:array, :map} do
      default []
      public? true
      description "Network interfaces (OCSF Network Interface objects)"
    end

    attribute :owner, :map do
      default %{}
      public? true
      description "Device owner (OCSF User object)"
    end

    attribute :org, :map do
      default %{}
      public? true
      description "Organization (OCSF Organization object)"
    end

    attribute :groups, {:array, :map} do
      default []
      public? true
      description "Device groups (OCSF Group objects)"
    end

    attribute :agent_list, {:array, :map} do
      default []
      public? true
      description "Associated agents (OCSF Agent objects)"
    end

    # ServiceRadar-specific fields
    attribute :poller_id, :string do
      public? true
      description "Poller that discovered this device"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent reporting this device"
    end

    attribute :discovery_sources, {:array, :string} do
      default []
      public? true
      description "List of discovery source types"
    end

    attribute :is_available, :boolean do
      default true
      public? true
      description "Current availability status"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this device belongs to"
    end
  end

  identities do
    identity :unique_uid, [:uid]
    # MAC uniqueness is optional - skipping unique index
    # identity :unique_mac, [:mac], where: expr(not is_nil(mac))
  end

  actions do
    defaults [:read]

    read :by_uid do
      argument :uid, :string, allow_nil?: false
      get? true
      filter expr(uid == ^arg(:uid))
    end

    read :by_ip do
      argument :ip, :string, allow_nil?: false
      filter expr(ip == ^arg(:ip))
    end

    read :by_mac do
      argument :mac, :string, allow_nil?: false
      filter expr(mac == ^arg(:mac))
    end

    read :by_poller do
      argument :poller_id, :string, allow_nil?: false
      filter expr(poller_id == ^arg(:poller_id))
    end

    read :available do
      description "Devices currently available"
      filter expr(is_available == true)
    end

    read :recently_seen do
      description "Devices seen in the last hour"
      filter expr(last_seen_time > ago(1, :hour))
    end

    create :create do
      accept [
        :uid, :type_id, :type, :name, :hostname, :ip, :mac,
        :uid_alt, :vendor_name, :model, :domain, :zone,
        :subnet_uid, :vlan_uid, :region,
        :first_seen_time, :last_seen_time, :created_time, :modified_time,
        :risk_level_id, :risk_level, :risk_score,
        :is_managed, :is_compliant, :is_trusted,
        :os, :hw_info, :network_interfaces, :owner, :org, :groups, :agent_list,
        :poller_id, :agent_id, :discovery_sources, :is_available, :metadata
      ]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_new_attribute(:first_seen_time, now)
        |> Ash.Changeset.change_new_attribute(:last_seen_time, now)
        |> Ash.Changeset.change_new_attribute(:created_time, now)
      end
    end

    update :update do
      accept [
        :name, :hostname, :ip, :mac,
        :vendor_name, :model, :domain, :zone,
        :risk_level_id, :risk_level, :risk_score,
        :is_managed, :is_compliant, :is_trusted,
        :os, :hw_info, :network_interfaces, :owner, :org, :groups, :agent_list,
        :is_available, :metadata
      ]

      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :touch do
      description "Update last_seen_time without other changes"
      change set_attribute(:last_seen_time, &DateTime.utc_now/0)
    end

    update :set_availability do
      accept [:is_available]
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end
  end

  calculations do
    calculate :type_name, :string, expr(
      cond do
        not is_nil(type) -> type
        type_id == 0 -> "Unknown"
        type_id == 1 -> "Server"
        type_id == 2 -> "Desktop"
        type_id == 3 -> "Laptop"
        type_id == 4 -> "Tablet"
        type_id == 5 -> "Mobile"
        type_id == 6 -> "Virtual"
        type_id == 7 -> "IOT"
        type_id == 8 -> "Browser"
        type_id == 9 -> "Firewall"
        type_id == 10 -> "Switch"
        type_id == 11 -> "Hub"
        type_id == 12 -> "Router"
        type_id == 13 -> "IDS"
        type_id == 14 -> "IPS"
        type_id == 15 -> "Load Balancer"
        type_id == 99 -> "Other"
        true -> "Unknown"
      end
    )

    calculate :display_name, :string, expr(
      cond do
        not is_nil(name) -> name
        not is_nil(hostname) -> hostname
        not is_nil(ip) -> ip
        true -> uid
      end
    )

    calculate :is_stale, :boolean, expr(
      is_nil(last_seen_time) or last_seen_time < ago(24, :hour)
    )

    calculate :status_color, :string, expr(
      cond do
        is_available == true and last_seen_time > ago(5, :minute) -> "green"
        is_available == true and last_seen_time > ago(1, :hour) -> "yellow"
        true -> "red"
      end
    )
  end

  code_interface do
    define :get_by_uid, action: :by_uid, args: [:uid]
    define :get_by_ip, action: :by_ip, args: [:ip]
    define :get_by_mac, action: :by_mac, args: [:mac]
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # All authenticated users can read devices
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Operators and admins can create devices
    policy action(:create) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Operators and admins can update devices
    policy action([:update, :touch, :set_availability]) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end
end
