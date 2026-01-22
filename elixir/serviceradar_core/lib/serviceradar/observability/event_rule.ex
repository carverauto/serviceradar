defmodule ServiceRadar.Observability.EventRule do
  @moduledoc """
  Unified rules for creating OCSF events from multiple sources.

  Log-based rules mirror legacy log promotion rules. Metric-based rules
  are created from interface metric configurations and generate events
  directly without a log promotion step.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "event_rules"
    repo ServiceRadar.Repo
  end

  code_interface do
    define :list, action: :read
    define :list_active, action: :active
    define :create, action: :create
    define :update, action: :update
    define :destroy, action: :destroy
  end

  actions do
    defaults [:read, :destroy]

    read :active do
      filter expr(enabled == true)
      prepare build(sort: [priority: :asc, inserted_at: :asc])
    end

    create :create do
      accept [:name, :enabled, :priority, :source_type, :source, :match, :event]
    end

    update :update do
      accept [:name, :enabled, :priority, :source_type, :source, :match, :event]
    end
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

    policy action([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
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

    attribute :source_type, :atom do
      allow_nil? false
      default :log
      public? true
      constraints one_of: [:log, :metric]
    end

    attribute :source, :map do
      default %{}
      public? true
    end

    attribute :match, :map do
      default %{}
      public? true
    end

    attribute :event, :map do
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
