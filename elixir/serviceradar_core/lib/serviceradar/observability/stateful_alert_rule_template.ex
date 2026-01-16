defmodule ServiceRadar.Observability.StatefulAlertRuleTemplate do
  @moduledoc """
  Templates for stateful alert rule presets.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "stateful_alert_rule_templates"
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
        :priority,
        :signal,
        :match,
        :group_by,
        :threshold,
        :window_seconds,
        :bucket_seconds,
        :cooldown_seconds,
        :renotify_seconds,
        :event,
        :alert
      ]
    end

    update :update do
      accept [
        :name,
        :description,
        :enabled,
        :priority,
        :signal,
        :match,
        :group_by,
        :threshold,
        :window_seconds,
        :bucket_seconds,
        :cooldown_seconds,
        :renotify_seconds,
        :event,
        :alert
      ]
    end
  end

  identities do
    identity :unique_name, [:name]
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
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

    attribute :priority, :integer do
      default 100
      public? true
    end

    attribute :signal, :atom do
      default :log
      allow_nil? false
      public? true
      constraints one_of: [:log, :event]
    end

    attribute :match, :map do
      default %{}
      public? true
    end

    attribute :group_by, {:array, :string} do
      default ["serviceradar.sync.integration_source_id"]
      public? true
    end

    attribute :threshold, :integer do
      default 5
      allow_nil? false
      public? true
    end

    attribute :window_seconds, :integer do
      default 600
      allow_nil? false
      public? true
    end

    attribute :bucket_seconds, :integer do
      default 60
      allow_nil? false
      public? true
    end

    attribute :cooldown_seconds, :integer do
      default 300
      allow_nil? false
      public? true
    end

    attribute :renotify_seconds, :integer do
      default 21_600
      allow_nil? false
      public? true
    end

    attribute :event, :map do
      default %{}
      public? true
    end

    attribute :alert, :map do
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
