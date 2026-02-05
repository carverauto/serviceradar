defmodule ServiceRadar.Identity.AuthorizationSettings do
  @moduledoc """
  Instance-level authorization settings.

  Stores the default role and IdP claim/group role mappings used during login
  and user provisioning.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.Identity.AuthorizationSettingsNotifier]

  postgres do
    table "authorization_settings"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :create_settings, action: :create
    define :update_settings, action: :update
  end

  actions do
    defaults [:read]

    read :get_singleton do
      description "Get the singleton authorization settings"
      get? true
      filter expr(key == "default")
    end

    create :create do
      description "Create authorization settings"
      accept [:default_role, :role_mappings]
      change set_attribute(:key, "default")
    end

    update :update do
      description "Update authorization settings"
      accept [:default_role, :role_mappings]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    attribute :key, :string do
      allow_nil? false
      default "default"
      primary_key? true
      public? false
    end

    attribute :default_role, :atom do
      allow_nil? false
      default :viewer
      public? true
      constraints one_of: [:viewer, :operator, :admin]
      description "Default role assigned when no mapping matches"
    end

    attribute :role_mappings, {:array, :map} do
      allow_nil? false
      default []
      public? true
      description "List of role mappings derived from IdP claims or groups"
    end

    timestamps()
  end

end
