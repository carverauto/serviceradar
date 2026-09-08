defmodule ServiceRadar.Inventory.DeviceAgentAvailability do
  @moduledoc """
  Latest per-agent availability state for an inventory device.

  Historical sweep rows remain in `SweepHostResult`; this resource stores the
  current projection for each `{device, agent}` pair so the UI, SRQL, and
  integrations can distinguish "available from this agent" from the canonical
  device availability field.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @create_fields [
    :device_uid,
    :agent_id,
    :agent_name,
    :is_available,
    :checked_at,
    :response_time_ms,
    :open_ports,
    :sweep_modes_results,
    :sweep_group_id,
    :execution_id,
    :metadata
  ]

  @update_fields @create_fields -- [:device_uid, :agent_id]

  postgres do
    table "device_agent_availability"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:device_uid, :agent_id],
        unique: true,
        name: "device_agent_availability_device_agent_uidx"

      index [:device_uid], name: "device_agent_availability_device_uid_idx"
      index [:agent_id], name: "device_agent_availability_agent_id_idx"

      index [:device_uid, :checked_at],
        name: "device_agent_availability_device_checked_at_idx"
    end
  end

  code_interface do
    define :get_by_device_agent, action: :by_device_agent, args: [:device_uid, :agent_id]
    define :list_by_device, action: :by_device, args: [:device_uid]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @create_fields
    end

    update :update do
      accept @update_fields
    end

    update :reassign_device do
      description "Repoint the row to a canonical device (used during merges)"
      accept [:device_uid]
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false

      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [checked_at: :desc, agent_id: :asc])
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false

      filter expr(agent_id == ^arg(:agent_id))
      prepare build(sort: [checked_at: :desc, device_uid: :asc])
    end

    read :by_device_agent do
      argument :device_uid, :string, allow_nil?: false
      argument :agent_id, :string, allow_nil?: false

      get? true
      filter expr(device_uid == ^arg(:device_uid) and agent_id == ^arg(:agent_id))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :device_uid, :string do
      allow_nil? false
      public? true
      description "Device UID this latest availability row belongs to"
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
      description "Agent that produced this latest availability result"
    end

    attribute :agent_name, :string do
      public? true
      description "Display name captured for the reporting agent"
    end

    attribute :is_available, :boolean do
      allow_nil? false
      public? true
      description "Latest availability result from this agent"
    end

    attribute :checked_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When this agent last checked the device"
    end

    attribute :response_time_ms, :integer do
      public? true
      description "Latest response time reported by this agent"
    end

    attribute :open_ports, {:array, :integer} do
      allow_nil? false
      default []
      public? true
      description "Latest open ports reported by this agent"
    end

    attribute :sweep_modes_results, :map do
      allow_nil? false
      default %{}
      public? true
      description "Latest ICMP/TCP mode results reported by this agent"
    end

    attribute :sweep_group_id, :uuid do
      public? true
      description "Sweep group that produced the latest result"
    end

    attribute :execution_id, :uuid do
      public? true
      description "Sweep execution that produced the latest result"
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
      description "Additional latest-result metadata"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      define_attribute? false
      allow_nil? false
      public? true
    end

    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_id
      destination_attribute :uid
      define_attribute? false
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_device_agent, [:device_uid, :agent_id]
  end
end
