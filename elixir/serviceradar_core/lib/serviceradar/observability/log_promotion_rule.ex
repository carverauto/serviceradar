defmodule ServiceRadar.Observability.LogPromotionRule do
  @moduledoc """
  Per-tenant rules for promoting logs into OCSF events.

  Rules are evaluated in priority order and can match on log fields plus
  attributes/resource_attributes. Event metadata is stored in the rule's
  `event` map and merged with generated defaults.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "log_promotion_rules"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :create, :update, :destroy]

    read :active do
      filter expr(enabled == true)
      prepare build(sort: [priority: :asc, inserted_at: :asc])
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

    attribute :enabled, :boolean do
      default true
      public? true
    end

    attribute :priority, :integer do
      default 100
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

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
