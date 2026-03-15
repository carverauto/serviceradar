defmodule ServiceRadar.Identity.AuthorizationSettings do
  @moduledoc """
  Instance-level authorization settings.

  Stores the default role and IdP claim/group role mappings used during login
  and user provisioning.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.Identity.AuthorizationSettingsNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Identity.Validations.RoleMappings

  @allowed_roles Constants.allowed_roles()
  @auth_manage_permission Constants.auth_manage_permission()
  @auth_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                      permission: @auth_manage_permission}
  @settings_fields [:default_role, :role_mappings]

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
      accept @settings_fields
      change set_attribute(:key, "default")
      validate RoleMappings
    end

    update :update do
      description "Update authorization settings"
      accept @settings_fields
      validate RoleMappings
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    read_with_permission(@auth_manage_check)

    action_with_permission([:create, :update], @auth_manage_check)
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
      constraints one_of: @allowed_roles
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
