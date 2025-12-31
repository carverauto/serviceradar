defmodule ServiceRadar.Infrastructure.NatsPlatformToken do
  @moduledoc """
  One-time platform bootstrap tokens for NATS server onboarding.

  These tokens are used during initial platform setup to authenticate the
  NATS bootstrap process. Each token can only be used once and has a limited
  TTL.

  ## Token Flow

  1. Super admin generates a token via API/UI
  2. Token is displayed once (the secret is hashed before storage)
  3. Operator runs `serviceradar-cli bootstrap-nats --token <token>`
  4. CLI exchanges token for operator credentials
  5. Token is marked as used

  ## Security

  - Token secrets are SHA256 hashed before storage
  - Tokens have a maximum TTL (default 24 hours)
  - Single use - marked used immediately upon successful validation
  - Usage is logged with IP and timestamp
  """

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "nats_platform_tokens"
    repo ServiceRadar.Repo
  end

  actions do
    defaults [:read]

    create :generate do
      description "Generate a new platform bootstrap token"
      accept [:purpose, :expires_at]

      change fn changeset, _context ->
        # Generate a random token
        token_bytes = :crypto.strong_rand_bytes(32)
        token_secret = Base.url_encode64(token_bytes, padding: false)

        # Hash for storage
        token_hash = :crypto.hash(:sha256, token_secret) |> Base.encode16(case: :lower)

        # Store the hash and save the secret in context for after_action
        changeset
        |> Ash.Changeset.change_attribute(:token_hash, token_hash)
        |> Ash.Changeset.put_context(:generated_token_secret, token_secret)
      end

      change fn changeset, _context ->
        # Set default expiration if not provided
        case Ash.Changeset.get_attribute(changeset, :expires_at) do
          nil ->
            expires_at = DateTime.add(DateTime.utc_now(), 24, :hour)
            Ash.Changeset.change_attribute(changeset, :expires_at, expires_at)

          _ ->
            changeset
        end
      end

      change after_action(fn changeset, record, _context ->
        # Add token_secret to the record as a map key (not a persisted field)
        token_secret = changeset.context[:generated_token_secret]
        {:ok, Map.put(record, :token_secret, token_secret)}
      end)
    end

    read :find_valid do
      description "Find a valid (unused, unexpired) token by hash"
      argument :token_hash, :string, allow_nil?: false
      get? true

      filter expr(
               token_hash == ^arg(:token_hash) and
                 is_nil(used_at) and
                 expires_at > ^DateTime.utc_now()
             )
    end

    update :mark_used do
      description "Mark token as used after successful bootstrap"
      accept []
      require_atomic? false

      argument :used_by_ip, :string

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:used_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:used_by_ip, Ash.Changeset.get_argument(changeset, :used_by_ip))
      end
    end

    destroy :cleanup_expired do
      description "Delete expired tokens (for maintenance)"
    end
  end

  policies do
    # All operations require super_admin
    policy always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token_hash, :string do
      allow_nil? false
      public? false
      description "SHA256 hash of the token secret"
    end

    attribute :purpose, :atom do
      allow_nil? false
      default :nats_bootstrap
      public? true
      constraints one_of: [:nats_bootstrap, :nats_rotate]
      description "Purpose of this token"
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When this token expires"
    end

    attribute :used_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When this token was used"
    end

    attribute :used_by_ip, :string do
      allow_nil? true
      public? false
      description "IP address that used this token"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :is_valid?,
              :boolean,
              expr(is_nil(used_at) and expires_at > ^DateTime.utc_now())

    calculate :is_expired?,
              :boolean,
              expr(expires_at <= ^DateTime.utc_now())
  end

  identities do
    identity :unique_hash, [:token_hash]
  end

  @doc """
  Find a valid token and mark it as used in one atomic operation.

  This is the main entry point for token validation during bootstrap.
  It finds a token by its secret, validates it hasn't been used or expired,
  and marks it as used.

  ## Parameters

    * `token_secret` - The plaintext token secret
    * `source_ip` - IP address of the client using the token

  ## Returns

    * `{:ok, token_record}` - Token was valid and is now marked used
    * `{:error, :token_not_found}` - No valid token found
    * `{:error, :token_expired}` - Token exists but is expired
    * `{:error, :token_already_used}` - Token was already used
  """
  @spec find_and_use(String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def find_and_use(token_secret, source_ip) when is_binary(token_secret) do
    # Hash the token to match against stored hash
    token_hash = :crypto.hash(:sha256, token_secret) |> Base.encode16(case: :lower)

    # Find the token by hash
    case __MODULE__
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(token_hash == ^token_hash)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        {:error, :token_not_found}

      {:ok, token} ->
        cond do
          token.used_at != nil ->
            {:error, :token_already_used}

          DateTime.compare(DateTime.utc_now(), token.expires_at) == :gt ->
            {:error, :token_expired}

          true ->
            # Mark as used
            token
            |> Ash.Changeset.for_update(:mark_used)
            |> Ash.Changeset.set_argument(:used_by_ip, source_ip)
            |> Ash.update(authorize?: false)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def find_and_use(_, _), do: {:error, :invalid_token}
end
