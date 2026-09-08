defmodule ServiceRadar.Inventory.AvailabilitySourceProfile do
  @moduledoc """
  SRQL-scoped canonical availability source assignment profile.

  Profiles let operators select an agent as the canonical availability source for
  devices matching an SRQL device query. Per-device overrides still live on
  `Device.availability_source_agent_id` with no profile id.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Inventory.Validations.AvailabilitySourceProfileTargetQuery

  @create_fields [
    :name,
    :description,
    :srql_query,
    :agent_id,
    :enabled,
    :priority,
    :metadata
  ]

  @update_fields @create_fields ++ [:match_count, :applied_count, :last_evaluated_at]

  postgres do
    table "availability_source_profiles"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index ["lower(name)"],
        unique: true,
        name: "availability_source_profiles_name_uidx"

      index [:enabled, :priority], name: "availability_source_profiles_enabled_priority_idx"
      index [:agent_id], name: "availability_source_profiles_agent_id_idx"
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_enabled, action: :enabled
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :enabled do
      filter expr(enabled == true)
      prepare build(sort: [priority: :desc, id: :asc])
    end

    create :create do
      accept @create_fields
      validate AvailabilitySourceProfileTargetQuery
    end

    update :update do
      accept @update_fields
      validate AvailabilitySourceProfileTargetQuery
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update, :destroy])
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :srql_query, :string do
      allow_nil? false
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :priority, :integer do
      allow_nil? false
      default 100
      public? true
    end

    attribute :match_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :applied_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :last_evaluated_at, :utc_datetime_usec do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_id
      destination_attribute :uid
      define_attribute? false
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
