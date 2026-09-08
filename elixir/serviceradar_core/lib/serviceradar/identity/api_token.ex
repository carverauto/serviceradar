defmodule ServiceRadar.Identity.ApiToken do
  @moduledoc """
  API Token resource for programmatic access.

  API tokens enable CLI tools, automation scripts, and external integrations
  to authenticate with the ServiceRadar API. Each token has a scope that
  limits what actions it can perform.

  ## Token Scopes

  - `read` - Read-only access to resources
  - `write` - Read and write access to resources
  - `admin` - Full administrative access

  ## Security

  - Tokens are stored as hashed values
  - Original token is only shown once at creation time
  - Tokens can be revoked at any time
  - Optional expiration dates are supported
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Identity.AccessCredentialChanges

  @token_create_fields [:name, :description, :scope, :expires_at, :metadata, :user_id]
  @token_update_fields [:name, :description, :expires_at, :metadata]
  @token_usage_fields [:last_used_ip]
  @token_self_manage_actions [:update, :record_use, :revoke, :disable, :enable]

  postgres do
    table "api_tokens"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_active, action: :active
    define :list_by_user, action: :by_user, args: [:user_id]
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_prefix do
      argument :prefix, :string, allow_nil?: false
      filter expr(token_prefix == ^arg(:prefix) and enabled == true and is_nil(revoked_at))
    end

    read :active do
      description "All active (non-revoked, non-expired) tokens"

      filter expr(
               enabled == true and
                 is_nil(revoked_at) and
                 (is_nil(expires_at) or expires_at > now())
             )
    end

    read :by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    create :create do
      description "Create a new API token"
      accept @token_create_fields

      argument :token, :string do
        allow_nil? false
        sensitive? true
        description "The raw token to hash and store"
      end

      change fn changeset, _context ->
        AccessCredentialChanges.init_secret(changeset,
          argument: :token,
          hash_attribute: :token_hash,
          prefix_attribute: :token_prefix,
          timestamp_attribute: :created_at,
          hash_fun: fn raw_token ->
            :sha256 |> :crypto.hash(raw_token) |> Base.encode16(case: :lower)
          end
        )
      end
    end

    update :update do
      accept @token_update_fields
    end

    update :record_use do
      description "Record token usage"
      accept @token_usage_fields
      change atomic_update(:last_used_at, expr(now()))
      change atomic_update(:use_count, expr(use_count + 1))
    end

    update :revoke do
      description "Revoke this token"
      # Non-atomic: uses function change to set multiple attributes
      require_atomic? false
      argument :revoked_by, :string, allow_nil?: true

      change fn changeset, _context ->
        revoked_by = Ash.Changeset.get_argument(changeset, :revoked_by) || "system"

        AccessCredentialChanges.revoke(changeset, revoked_by: revoked_by)
      end
    end

    update :disable do
      description "Disable this token"
      change set_attribute(:enabled, false)
    end

    update :enable do
      description "Enable this token"
      change set_attribute(:enabled, true)
    end
  end

  policies do
    import ServiceRadar.Policies

    # System actors can perform all operations (schema isolation via search_path)
    system_bypass()

    # Users can read their own tokens
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if is_admin()
    end

    # Users can create tokens for themselves
    # Note: create actions cannot use expr() filters that reference record attributes
    # because the record doesn't exist yet. We use a custom check instead.
    policy action(:create) do
      authorize_if ServiceRadar.Identity.ApiToken.Checks.CreatingOwnToken
      authorize_if is_admin()
    end

    # Users can update/revoke their own tokens
    policy action(@token_self_manage_actions) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if is_admin()
    end
  end

  changes do
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Token display name"
    end

    attribute :description, :string do
      public? true
      description "Token description/purpose"
    end

    attribute :token_hash, :string do
      allow_nil? false
      public? false
      sensitive? true
      description "Hashed token value"
    end

    attribute :token_prefix, :string do
      allow_nil? false
      public? true
      description "First 8 characters of the token for identification"
    end

    attribute :scope, :string do
      default "read"
      public? true
      description "Token scope (read, write, admin)"
    end

    attribute :enabled, :boolean do
      default true
      public? true
      description "Whether this token is active"
    end

    attribute :expires_at, :utc_datetime do
      public? true
      description "Optional expiration time"
    end

    attribute :last_used_at, :utc_datetime do
      public? true
      description "When token was last used"
    end

    attribute :last_used_ip, :string do
      public? true
      description "IP address of last use"
    end

    attribute :use_count, :integer do
      default 0
      public? true
      description "Number of times token has been used"
    end

    attribute :revoked_at, :utc_datetime do
      public? true
      description "When token was revoked"
    end

    attribute :revoked_by, :string do
      public? true
      description "Who revoked the token"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    attribute :created_at, :utc_datetime do
      public? true
      description "When token was created"
    end

    # User who created the token
    attribute :user_id, :uuid do
      allow_nil? false
      public? true
      description "User who created this token"
    end
  end

  relationships do
    belongs_to :user, ServiceRadar.Identity.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :is_valid,
              :boolean,
              expr(
                enabled == true and
                  is_nil(revoked_at) and
                  (is_nil(expires_at) or expires_at > now())
              )

    calculate :is_expired, :boolean, expr(not is_nil(expires_at) and expires_at <= now())

    calculate :is_revoked, :boolean, expr(not is_nil(revoked_at))

    calculate :scope_label,
              :string,
              expr(
                cond do
                  scope == "read" -> "Read Only"
                  scope == "write" -> "Read/Write"
                  scope == "admin" -> "Admin"
                  true -> scope
                end
              )

    calculate :status,
              :string,
              expr(
                cond do
                  not is_nil(revoked_at) -> "revoked"
                  not is_nil(expires_at) and expires_at <= now() -> "expired"
                  enabled == false -> "disabled"
                  true -> "active"
                end
              )

    calculate :status_color,
              :string,
              expr(
                cond do
                  not is_nil(revoked_at) -> "red"
                  not is_nil(expires_at) and expires_at <= now() -> "orange"
                  enabled == false -> "gray"
                  true -> "green"
                end
              )
  end
end
