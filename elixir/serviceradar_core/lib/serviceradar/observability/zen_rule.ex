defmodule ServiceRadar.Observability.ZenRule do
  @moduledoc """
  Zen rule definitions for log normalization.

  Rules compile to GoRules/Zen JSON decision models and are synced to KV so
  the zen consumer can reload them without manual JSON edits.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "zen_rules"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  code_interface do
    define :list, action: :read
    define :list_active, action: :active
    define :create, action: :create
    define :update, action: :update
    define :destroy, action: :destroy
  end

  actions do
    defaults [:read]

    read :active do
      filter expr(enabled == true)
      prepare build(sort: [order: :asc, inserted_at: :asc])
    end

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
        :jdm_definition,
        :agent_id
      ]

      change ServiceRadar.Observability.Changes.CompileZenRule
      change ServiceRadar.Observability.Changes.SyncZenRule
      validate ServiceRadar.Observability.Validations.ZenRule
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
        :jdm_definition,
        :agent_id
      ]

      change ServiceRadar.Observability.Changes.CompileZenRule
      change ServiceRadar.Observability.Changes.SyncZenRule
      validate ServiceRadar.Observability.Validations.ZenRule
    end

    update :set_kv_revision do
      accept [:kv_revision]
    end

    destroy :destroy do
      change ServiceRadar.Observability.Changes.SyncZenRule
    end
  end

  identities do
    identity :unique_name, [:subject, :name]
  end

  policies do

    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:create, :update, :destroy, :set_kv_revision]) do
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

    attribute :format, :atom do
      allow_nil? false
      default :json
      public? true
      constraints one_of: [:json, :protobuf, :otel_metrics]
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

    # User-authored JDM definition from the visual/JSON editor
    # When present, this takes precedence over template + builder_config
    attribute :jdm_definition, :map do
      public? true
      description "User-authored JDM JSON from the rule editor (takes precedence over template)"
    end

    attribute :compiled_jdm, :map do
      default %{}
      public? false
    end

    attribute :kv_revision, :integer do
      public? false
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
