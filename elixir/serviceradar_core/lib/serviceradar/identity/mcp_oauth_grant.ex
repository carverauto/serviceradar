defmodule ServiceRadar.Identity.McpOAuthGrant do
  @moduledoc """
  Persistent consent grant for MCP authorization-code clients.

  Binds the first-party public client `serviceradar-mcp` to a user and,
  when the user signed in via SSO, to the IdP session (`sid` /
  SessionIndex plus an encrypted IdP refresh token when issued).
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @auth_methods [:oidc, :saml, :password]
  @mcp_manage_check {ActorHasPermission, permission: Constants.mcp_manage_permission()}

  postgres do
    table "mcp_oauth_grants"
    repo ServiceRadar.Repo
    schema "platform"
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:idp_refresh_token])
    decrypt_by_default([:idp_refresh_token])
  end

  code_interface do
    define :create
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_user, action: :by_user, args: [:user_id]
    define :active_for, action: :active_for, args: [:user_id, :client_id]
    define :by_idp_sid, action: :by_idp_sid, args: [:idp_iss, :idp_sid]
    define :revoke
    define :bind_idp
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :active_for do
      argument :user_id, :uuid, allow_nil?: false
      argument :client_id, :string, allow_nil?: false
      get? true

      filter expr(
               user_id == ^arg(:user_id) and client_id == ^arg(:client_id) and is_nil(revoked_at)
             )
    end

    read :by_idp_sid do
      argument :idp_iss, :string, allow_nil?: false
      argument :idp_sid, :string, allow_nil?: false
      filter expr(idp_iss == ^arg(:idp_iss) and idp_sid == ^arg(:idp_sid) and is_nil(revoked_at))
    end

    create :create do
      accept [
        :user_id,
        :client_id,
        :scope,
        :auth_method,
        :idp_iss,
        :idp_sid,
        :idp_refresh_token
      ]
    end

    update :revoke do
      change atomic_update(:revoked_at, expr(now()))
    end

    update :bind_idp do
      accept [:auth_method, :idp_iss, :idp_sid, :idp_refresh_token]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action([:create, :by_id, :by_idp_sid, :read]) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action(:by_user) do
      authorize_if expr(^arg(:user_id) == ^actor(:id))
      authorize_if is_admin()
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action([:by_user, :revoke]) do
      authorize_if @mcp_manage_check
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action(:active_for) do
      authorize_if expr(^arg(:user_id) == ^actor(:id))
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action([:revoke, :bind_idp]) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if is_admin()
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :user_id, :uuid, allow_nil?: false, public?: true
    attribute :client_id, :string, allow_nil?: false, public?: true
    attribute :scope, :string, allow_nil?: false, public?: true

    attribute :auth_method, :atom do
      allow_nil? false
      constraints one_of: @auth_methods
      public? true
    end

    attribute :idp_iss, :string, public?: true
    attribute :idp_sid, :string, public?: true

    attribute :idp_refresh_token, :string do
      sensitive? true
      public? false
    end

    attribute :revoked_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, ServiceRadar.Identity.User do
      source_attribute :user_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
    end
  end
end
