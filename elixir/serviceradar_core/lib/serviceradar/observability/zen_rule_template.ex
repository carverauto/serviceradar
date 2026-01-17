defmodule ServiceRadar.Observability.ZenRuleTemplate do
  @moduledoc """
  Templates for Zen rule builder presets.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "zen_rule_templates"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  code_interface do
    define :list, action: :read
    define :create, action: :create
    define :update, action: :update
    define :destroy, action: :destroy
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :description,
        :enabled,
        :order,
        :stream_name,
        :subject,
        :template,
        :builder_config,
        :agent_id
      ]

      validate ServiceRadar.Observability.Validations.ZenRuleTemplate
    end

    update :update do
      accept [
        :name,
        :description,
        :enabled,
        :order,
        :stream_name,
        :subject,
        :template,
        :builder_config,
        :agent_id
      ]

      validate ServiceRadar.Observability.Validations.ZenRuleTemplate
    end
  end

  identities do
    identity :unique_name, [:subject, :name]
  end

  policies do
    bypass always() do
    end

    # System actors can perform all operations (tenant isolation via schema)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  changes do
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

    attribute :enabled, :boolean do
      default true
      public? true
    end

    attribute :order, :integer do
      default 100
      public? true
    end

    attribute :stream_name, :string do
      allow_nil? false
      default "events"
      public? true
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
    end

    attribute :template, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:passthrough, :strip_full_message, :cef_severity, :snmp_severity]
    end

    attribute :builder_config, :map do
      default %{}
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      default "default-agent"
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
