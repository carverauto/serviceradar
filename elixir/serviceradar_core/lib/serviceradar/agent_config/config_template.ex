defmodule ServiceRadar.AgentConfig.ConfigTemplate do
  @moduledoc """
  Reusable configuration templates for agent configs.

  Templates define the schema and default values for a specific config type.
  They can be instance-specific or admin-only (admin_only: true).
  """

  use Ash.Resource,
    domain: ServiceRadar.AgentConfig,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "agent_config_templates"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :description,
        :config_type,
        :schema,
        :default_values,
        :admin_only,
        :enabled
      ]
    end

    update :update do
      accept [
        :name,
        :description,
        :schema,
        :default_values,
        :admin_only,
        :enabled
      ]
    end

    read :by_config_type do
      argument :config_type, :atom, allow_nil?: false

      filter expr(config_type == ^arg(:config_type) and enabled == true)
    end

    read :list_for_user do
      argument :is_admin, :boolean, default: false

      filter expr(
               enabled == true and
                 (admin_only == false or ^arg(:is_admin) == true)
             )
    end
  end

  policies do
    # System actors can do anything

    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Admins can manage templates
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # All authenticated users in the instance can read non-admin templates
    policy action_type(:read) do
      authorize_if expr(admin_only == false)
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable template name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Template description"
    end

    attribute :config_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:sweep, :sysmon, :snmp, :mapper]
      description "Type of configuration this template produces"
    end

    attribute :schema, :map do
      allow_nil? true
      public? true
      default %{}
      description "JSON schema for validating config values"
    end

    attribute :default_values, :map do
      allow_nil? false
      public? true
      default %{}
      description "Default configuration values"
    end

    attribute :admin_only, :boolean do
      allow_nil? false
      public? true
      default false
      description "If true, only admins can use this template"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
      description "Whether this template is available for use"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :config_instances, ServiceRadar.AgentConfig.ConfigInstance do
      destination_attribute :template_id
    end
  end

  identities do
    identity :unique_name_and_type, [:name, :config_type]
  end
end
