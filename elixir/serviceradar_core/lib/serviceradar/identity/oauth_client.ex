defmodule ServiceRadar.Identity.OAuthClient do
  @moduledoc """
  OAuth2 Client resource for user self-service API credentials.

  OAuth clients enable users to create their own client credentials for
  programmatic API access using the OAuth2 Client Credentials flow.
  Each client has a client_id (UUID) and client_secret pair.

  ## Client Credentials Flow

  1. User creates an OAuthClient in the UI
  2. UI shows client_id and client_secret (secret shown only once)
  3. Application exchanges credentials at `/oauth/token`:
     ```
     POST /oauth/token
     Content-Type: application/x-www-form-urlencoded

     grant_type=client_credentials
     &client_id=<client_id>
     &client_secret=<client_secret>
     &scope=read write
     ```
  4. Server returns a JWT access token
  5. Application uses token in Authorization header

  ## Scopes

  - `read` - Read-only access to resources
  - `write` - Create and modify resources
  - `admin` - Full administrative access (requires admin user)

  ## Security

  - Client secrets are bcrypt hashed (never stored in plain text)
  - Only the first 8 characters (prefix) are stored for identification
  - Clients can be revoked at any time
  - Optional expiration dates are supported
  - Usage tracking for auditing
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "oauth_clients"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_prefix, action: :by_prefix, args: [:prefix]
    define :list_by_user, action: :by_user, args: [:user_id]
    define :list_active, action: :active
    define :authenticate, action: :authenticate, args: [:client_id, :client_secret]
    define :create
    define :update
    define :record_use
    define :revoke
    define :disable
    define :enable
    define :destroy
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
      filter expr(secret_prefix == ^arg(:prefix) and enabled == true and is_nil(revoked_at))
    end

    read :by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :active do
      description "All active (non-revoked, non-expired) clients"

      filter expr(
               enabled == true and
                 is_nil(revoked_at) and
                 (is_nil(expires_at) or expires_at > now())
             )
    end

    # Authenticate a client using client_id and client_secret
    read :authenticate do
      description "Authenticate using client credentials"
      argument :client_id, :uuid, allow_nil?: false
      argument :client_secret, :string, allow_nil?: false, sensitive?: true
      get? true
      filter expr(id == ^arg(:client_id) and enabled == true and is_nil(revoked_at))

      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, results ->
          case results do
            [client] ->
              secret = Ash.Query.get_argument(query, :client_secret)

              if Bcrypt.verify_pass(secret, client.secret_hash) do
                {:ok, [client]}
              else
                {:ok, []}
              end

            [] ->
              # Prevent timing attacks
              Bcrypt.no_user_verify()
              {:ok, []}
          end
        end)
      end
    end

    create :create do
      description "Create a new OAuth client"
      accept [:name, :description, :scopes, :expires_at, :user_id]

      argument :client_secret, :string do
        allow_nil? false
        sensitive? true
        description "The raw client secret to hash and store"
      end

      change fn changeset, _context ->
        secret = Ash.Changeset.get_argument(changeset, :client_secret)

        # Bcrypt hash the secret
        secret_hash = Bcrypt.hash_pwd_salt(secret)

        # Extract prefix for display
        secret_prefix = String.slice(secret, 0, 8)

        changeset
        |> Ash.Changeset.change_attribute(:secret_hash, secret_hash)
        |> Ash.Changeset.change_attribute(:secret_prefix, secret_prefix)
        |> Ash.Changeset.change_attribute(:enabled, true)
        |> Ash.Changeset.change_attribute(:use_count, 0)
      end
    end

    update :update do
      accept [:name, :description, :expires_at]
    end

    update :record_use do
      description "Record client usage"
      # Non-atomic: increments use_count based on current value
      require_atomic? false
      accept [:last_used_ip]

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:last_used_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(
          :use_count,
          (changeset.data.use_count || 0) + 1
        )
      end
    end

    update :revoke do
      description "Revoke this client"
      # Non-atomic: uses function change to set multiple attributes
      require_atomic? false

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:revoked_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:enabled, false)
      end
    end

    update :disable do
      description "Disable this client"
      change set_attribute(:enabled, false)
    end

    update :enable do
      description "Enable this client"
      change set_attribute(:enabled, true)
    end

    destroy :destroy do
      description "Delete this client"
    end
  end

  policies do
    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Users can read their own clients
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Authenticate action is public (no actor required)
    policy action(:authenticate) do
      authorize_if always()
    end

    # Users can create clients for themselves
    policy action(:create) do
      authorize_if ServiceRadar.Identity.OAuthClient.Checks.CreatingOwnClient
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Users can update/revoke/delete their own clients
    policy action([:update, :record_use, :revoke, :disable, :enable, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Client display name"
    end

    attribute :description, :string do
      public? true
      description "Client description/purpose"
    end

    # Credentials
    attribute :secret_hash, :string do
      allow_nil? false
      public? false
      sensitive? true
      description "Bcrypt-hashed client secret"
    end

    attribute :secret_prefix, :string do
      allow_nil? false
      public? true
      description "First 8 characters of the secret for identification"
      constraints max_length: 8
    end

    # Permissions
    attribute :scopes, {:array, :string} do
      allow_nil? false
      default ["read"]
      public? true
      description "Granted scopes (read, write, admin)"
    end

    # Status
    attribute :enabled, :boolean do
      default true
      public? true
      description "Whether this client is active"
    end

    attribute :revoked_at, :utc_datetime_usec do
      public? true
      description "When the client was revoked"
    end

    # Usage tracking
    attribute :last_used_at, :utc_datetime_usec do
      public? true
      description "When client was last used"
    end

    attribute :last_used_ip, :string do
      public? true
      description "IP address of last use"
    end

    attribute :use_count, :integer do
      default 0
      public? true
      description "Number of times client has been used"
    end

    # Expiration
    attribute :expires_at, :utc_datetime_usec do
      public? true
      description "Optional expiration time"
    end

    # User who owns this client
    attribute :user_id, :uuid do
      allow_nil? false
      public? true
      description "User who owns this client"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
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

    calculate :client_id, :string, expr(type(id, :string)) do
      description "Client ID (same as id, formatted as string)"
    end

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

    calculate :scopes_display, :string, expr(fragment("array_to_string(?, ', ')", scopes))
  end

  identities do
    # Clients are unique by their ID (primary key)
    # No need for additional uniqueness constraint
  end
end
