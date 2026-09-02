defmodule ServiceRadar.Identity.McpOAuthCode do
  @moduledoc """
  One-time authorization codes for the MCP authorization-code grant.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mcp_oauth_codes"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :create
    define :get_by_code_hash, action: :by_code_hash, args: [:code_hash]
    define :consume
  end

  actions do
    defaults [:read]

    read :by_code_hash do
      argument :code_hash, :string, allow_nil?: false
      get? true
      filter expr(code_hash == ^arg(:code_hash))
    end

    create :create do
      accept [
        :grant_id,
        :user_id,
        :client_id,
        :code_hash,
        :redirect_uri,
        :code_challenge,
        :scope,
        :expires_at
      ]
    end

    update :consume do
      change atomic_update(:consumed_at, expr(now()))
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
    attribute :grant_id, :uuid, allow_nil?: false, public?: true
    attribute :user_id, :uuid, allow_nil?: false, public?: true
    attribute :client_id, :string, allow_nil?: false, public?: true

    attribute :code_hash, :string do
      allow_nil? false
      sensitive? true
      public? false
    end

    attribute :redirect_uri, :string, allow_nil?: false, public?: true
    attribute :code_challenge, :string, allow_nil?: false, sensitive?: true, public?: false
    attribute :scope, :string, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :consumed_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_code_hash, [:code_hash]
  end
end
