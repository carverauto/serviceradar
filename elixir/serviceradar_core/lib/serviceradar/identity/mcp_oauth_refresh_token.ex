defmodule ServiceRadar.Identity.McpOAuthRefreshToken do
  @moduledoc """
  Rotating refresh tokens for MCP authorization-code grants.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mcp_oauth_refresh_tokens"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :create
    define :get_by_token_hash, action: :by_token_hash, args: [:token_hash]
    define :list_by_family, action: :by_family, args: [:family_id]
    define :list_by_grant, action: :by_grant, args: [:grant_id]
    define :revoke
  end

  actions do
    defaults [:read]

    read :by_token_hash do
      argument :token_hash, :string, allow_nil?: false
      get? true
      filter expr(token_hash == ^arg(:token_hash))
    end

    read :by_family do
      argument :family_id, :uuid, allow_nil?: false
      filter expr(family_id == ^arg(:family_id))
    end

    read :by_grant do
      argument :grant_id, :uuid, allow_nil?: false
      filter expr(grant_id == ^arg(:grant_id))
    end

    create :create do
      accept [
        :family_id,
        :grant_id,
        :user_id,
        :client_id,
        :token_hash,
        :scope,
        :expires_at
      ]
    end

    update :revoke do
      accept [:replaced_by_id]
      change atomic_update(:revoked_at, expr(now()))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type([:create, :read, :update]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :family_id, :uuid, allow_nil?: false, public?: true
    attribute :grant_id, :uuid, allow_nil?: false, public?: true
    attribute :user_id, :uuid, allow_nil?: false, public?: true
    attribute :client_id, :string, allow_nil?: false, public?: true

    attribute :token_hash, :string do
      allow_nil? false
      sensitive? true
      public? false
    end

    attribute :scope, :string, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true
    attribute :replaced_by_id, :uuid, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_token_hash, [:token_hash]
  end
end
