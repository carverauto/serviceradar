defmodule ServiceRadar.Inventory.EndpointInventorySettings do
  @moduledoc """
  Deployment-level endpoint inventory settings.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @edge_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                      permission: "settings.edge.manage"}
  @type t :: %__MODULE__{}

  postgres do
    table "endpoint_inventory_settings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :update_settings, action: :update
    define :create, action: :create
  end

  actions do
    defaults [:read]

    read :get_singleton do
      get? true

      prepare fn query, _ ->
        Ash.Query.limit(query, 1)
      end
    end

    create :create do
      accept [:retention_days]
    end

    update :update do
      accept [:retention_days]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if @edge_manage_check
    end

    policy action([:create, :update]) do
      authorize_if @edge_manage_check
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :retention_days, :integer do
      allow_nil? false
      default 30
      public? true
      constraints min: 1, max: 365
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
