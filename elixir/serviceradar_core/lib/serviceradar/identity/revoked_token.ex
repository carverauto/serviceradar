defmodule ServiceRadar.Identity.RevokedToken do
  @moduledoc """
  Durable JWT/session revocation markers.

  Revocation state lives in CNPG so every `web-ng` node observes the same
  session invalidation decisions.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "token_revocations"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_jti, action: :by_jti, args: [:jti]
    define :get_active_by_jti, action: :active_by_jti, args: [:jti]
    define :list_active, action: :active
    define :list_expired, action: :expired
  end

  actions do
    defaults [:read, :destroy]

    read :by_jti do
      argument :jti, :string, allow_nil?: false
      get? true
      filter expr(jti == ^arg(:jti))
    end

    read :active_by_jti do
      argument :jti, :string, allow_nil?: false
      get? true
      filter expr(jti == ^arg(:jti) and expires_at > now())
    end

    read :active do
      filter expr(expires_at > now())
    end

    read :expired do
      filter expr(expires_at <= now())
    end

    create :upsert do
      accept [:jti, :user_id, :reason, :revoked_at, :revoked_before, :expires_at]

      upsert? true
      upsert_identity :unique_jti
      upsert_fields [:user_id, :reason, :revoked_at, :revoked_before, :expires_at, :updated_at]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :jti, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :user_id, :uuid do
      public? true
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :revoked_before, :utc_datetime_usec do
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, ServiceRadar.Identity.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? true
      public? true
      define_attribute? false
    end
  end

  identities do
    identity :unique_jti, [:jti]
  end
end
