defmodule ServiceRadar.AgentConfig.ConfigInstance do
  @moduledoc """
  Compiled configuration instance for a specific agent or partition.

  ConfigInstance stores the compiled JSON configuration that agents poll for.
  It tracks version and content hash for change detection.
  """

  use Ash.Resource,
    domain: ServiceRadar.AgentConfig,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.AgentConfig.ConfigInvalidationNotifier]

  postgres do
    table "agent_config_instances"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:tenant_id, :config_type, :partition],
        name: "agent_config_instances_tenant_type_partition_idx"

      index [:tenant_id, :config_type, :agent_id],
        where: "agent_id IS NOT NULL",
        name: "agent_config_instances_tenant_type_agent_idx"
    end
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :config_type,
        :partition,
        :agent_id,
        :compiled_config,
        :source_ids
      ]

      change ServiceRadar.AgentConfig.Changes.ComputeConfigHash
      change ServiceRadar.AgentConfig.Changes.IncrementVersion
    end

    update :update do
      accept [
        :compiled_config,
        :source_ids
      ]

      require_atomic? false

      change ServiceRadar.AgentConfig.Changes.ComputeConfigHash
      change ServiceRadar.AgentConfig.Changes.IncrementVersion
      change ServiceRadar.AgentConfig.Changes.CreateVersionHistory
    end

    update :mark_delivered do
      accept []
      change set_attribute(:last_delivered_at, &DateTime.utc_now/0)
      change set_attribute(:delivery_count, expr(delivery_count + 1))
    end

    read :for_agent do
      argument :config_type, :atom, allow_nil?: false
      argument :partition, :string, allow_nil?: false
      argument :agent_id, :string, allow_nil?: true

      filter expr(
               config_type == ^arg(:config_type) and
                 partition == ^arg(:partition) and
                 (is_nil(^arg(:agent_id)) or agent_id == ^arg(:agent_id) or is_nil(agent_id))
             )
    end

    read :by_hash do
      argument :config_type, :atom, allow_nil?: false
      argument :partition, :string, allow_nil?: false
      argument :content_hash, :string, allow_nil?: false

      get? true

      filter expr(
               config_type == ^arg(:config_type) and
                 partition == ^arg(:partition) and
                 content_hash == ^arg(:content_hash)
             )
    end
  end

  policies do
    # Super admins can do anything
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # System actors can perform all operations (tenant isolation via schema)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Tenant admins can manage config instances
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # All authenticated users in tenant can read
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this config belongs to"
    end

    attribute :config_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:sweep, :poller, :checker]
      description "Type of configuration"
    end

    attribute :partition, :string do
      allow_nil? false
      public? true
      default "default"
      description "Partition this config is for"
    end

    attribute :agent_id, :string do
      allow_nil? true
      public? true
      description "Specific agent ID (nil = any agent in partition)"
    end

    attribute :compiled_config, :map do
      allow_nil? false
      public? true
      default %{}
      description "Compiled JSON configuration for agent consumption"
    end

    attribute :content_hash, :string do
      allow_nil? false
      public? true
      description "SHA256 hash of compiled_config for change detection"
    end

    attribute :version, :integer do
      allow_nil? false
      public? true
      default 1
      description "Config version number (increments on each update)"
    end

    attribute :source_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
      description "IDs of source resources that contributed to this config"
    end

    attribute :last_delivered_at, :utc_datetime do
      allow_nil? true
      public? true
      description "When config was last delivered to an agent"
    end

    attribute :delivery_count, :integer do
      allow_nil? false
      public? true
      default 0
      description "Number of times config has been delivered"
    end

    attribute :template_id, :uuid do
      allow_nil? true
      public? true
      description "Optional template this instance was derived from"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :template, ServiceRadar.AgentConfig.ConfigTemplate do
      allow_nil? true
      define_attribute? false
      destination_attribute :id
      source_attribute :template_id
    end

    has_many :versions, ServiceRadar.AgentConfig.ConfigVersion do
      destination_attribute :config_instance_id
    end
  end

  calculations do
    calculate :has_changes_since, :boolean, expr(updated_at > ^arg(:since)) do
      argument :since, :utc_datetime, allow_nil?: false
    end
  end

  identities do
    identity :unique_config_per_agent, [:tenant_id, :config_type, :partition, :agent_id]
  end
end
