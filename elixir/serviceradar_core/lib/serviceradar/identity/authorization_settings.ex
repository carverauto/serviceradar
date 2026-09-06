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
  @settings_fields [
    :default_role,
    :role_mappings,
    :cli_auth_enabled,
    :cli_session_ttl_days,
    :cli_allowed_scopes
  ]

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

    attribute :cli_auth_enabled, :boolean do
      allow_nil? false
      default true
      public? true

      description "Whether the RFC 8628 CLI device-code flow accepts new authorizations on this instance"
    end

    attribute :cli_session_ttl_days, :integer do
      allow_nil? false
      default 30
      public? true
      constraints min: 1, max: 365
      description "Default TTL (days) for JWTs issued by the CLI device-code flow"
    end

    attribute :cli_allowed_scopes, {:array, :string} do
      allow_nil? false
      default ["dashboard.publish", "plugin.publish", "plugins.manage"]
      public? true

      description "Scopes the CLI device-code flow may request; out-of-list scopes 400 with invalid_scope"
    end

    timestamps()
  end
end
