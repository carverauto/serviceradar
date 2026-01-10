defmodule ServiceRadar.Observability.StatefulAlertRule do
  @moduledoc """
  Stateful alert rule definitions for threshold windows (N occurrences in T).
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "stateful_alert_rules"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :destroy]

    read :active do
      filter expr(enabled == true)
      prepare build(sort: [priority: :asc, inserted_at: :asc])
    end

    create :create do
      validate ServiceRadar.Observability.Validations.WindowBucket
    end

    update :update do
      validate ServiceRadar.Observability.Validations.WindowBucket
    end
  end

  identities do
    identity :unique_name, [:tenant_id, :name]
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action_type(:read) do
      authorize_if expr(
                     ^actor(:role) in [:viewer, :operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    policy action([:create, :update, :destroy]) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end
  end

  changes do
    change ServiceRadar.Changes.AssignTenantId
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

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

end
