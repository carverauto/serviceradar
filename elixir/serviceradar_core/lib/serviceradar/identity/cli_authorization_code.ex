defmodule ServiceRadar.Identity.CliAuthorizationCode do
  @moduledoc """
  One-time PKCE authorization codes for `serviceradar-cli auth login --web`.

  The browser approval page inserts a row and redirects the plaintext code
  to the CLI's loopback listener. `POST /api/v1/cli/auth/token` looks the
  row up by hash, checks the S256 verifier, and burns it. Only the hash is
  stored.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # Remote `Ash.Expr.expr/1` is a macro. Without this require, Elixir
  # evaluates the filter body and rejects `consumed_at` as an unbound variable.
  require Ash.Expr

  postgres do
    table "cli_authorization_codes"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :create
    define :get_by_code_hash, action: :by_code_hash, args: [:code_hash]
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

    attribute :user_id, :uuid, allow_nil?: false, public?: true
    attribute :client_id, :string, allow_nil?: false, public?: true

    attribute :code_hash, :string do
      allow_nil? false
      sensitive? true
      public? false
    end

    attribute :redirect_uri, :string, allow_nil?: false, public?: true

    attribute :code_challenge, :string do
      allow_nil? false
      sensitive? true
      public? false
    end

    attribute :scope, :string, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :consumed_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_code_hash, [:code_hash]
  end

  @doc """
  Burns a code once.

  The `consumed_at` filter is applied on this changeset, not inside the
  `:consume` action. An action-level filter is dropped on the atomic path,
  so two exchanges of one code would both succeed.
  """
  def consume(record, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)

    record
    |> Ash.Changeset.for_update(:consume, %{}, actor: actor)
    |> Ash.Changeset.filter(Ash.Expr.expr(is_nil(consumed_at) and expires_at > now()))
    |> Ash.update()
  end
end
