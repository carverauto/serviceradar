defmodule ServiceRadar.Identity.User do
  @moduledoc """
  User resource for authentication and authorization.

  Maps to the existing `ng_users` table with multi-tenancy support.

  ## Roles

  - `:viewer` - Read-only access to tenant data
  - `:operator` - Can create and modify resources
  - `:admin` - Full tenant management including user management
  - `:super_admin` - Platform-wide access (not tenant-scoped)

  ## Authentication

  Users can authenticate via:
  - Password (with bcrypt hashing)
  - Magic link (email-based)
  - OAuth2 (future: Google, GitHub)
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  postgres do
    table "ng_users"
    repo ServiceRadarWebNG.Repo
  end

  authentication do
    tokens do
      enabled? true
      token_resource ServiceRadar.Identity.Token
      require_token_presence_for_authentication? true
      signing_secret fn _, _ ->
        Application.fetch_env(:serviceradar_web_ng, :token_signing_secret)
      end
    end

    strategies do
      password :password do
        identity_field :email
        hashed_password_field :hashed_password

        hash_provider AshAuthentication.BcryptProvider

        resettable do
          sender ServiceRadar.Identity.Senders.SendPasswordResetEmail
        end
      end

      magic_link :magic_link do
        identity_field :email
        require_interaction? true
        sender ServiceRadar.Identity.Senders.SendMagicLinkEmail
      end
    end

    add_ons do
      confirmation :confirm_email do
        monitor_fields [:email]
        require_interaction? true
        sender ServiceRadar.Identity.Senders.SendConfirmationEmail
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
      description "User email address (unique per tenant)"
    end

    attribute :hashed_password, :string do
      allow_nil? true
      sensitive? true
      description "Bcrypt-hashed password"
    end

    attribute :display_name, :string do
      public? true
      description "User's display name"
    end

    attribute :role, :atom do
      allow_nil? false
      default :viewer
      public? true
      constraints one_of: [:viewer, :operator, :admin, :super_admin]
      description "User's role for authorization"
    end

    attribute :confirmed_at, :utc_datetime do
      public? true
      description "When the user confirmed their email"
    end

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? true
      description "Owning tenant ID"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_email_per_tenant, [:tenant_id, :email]
    identity :unique_email, [:email]
  end

  relationships do
    belongs_to :tenant, ServiceRadar.Identity.Tenant do
      allow_nil? false
      attribute_type :uuid
      source_attribute :tenant_id
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  actions do
    defaults [:read]

    read :by_email do
      argument :email, :ci_string, allow_nil?: false
      get? true
      filter expr(email == ^arg(:email))
    end

    read :by_email_and_tenant do
      argument :email, :ci_string, allow_nil?: false
      argument :tenant_id, :uuid, allow_nil?: false
      get? true
      filter expr(email == ^arg(:email) and tenant_id == ^arg(:tenant_id))
    end

    read :admins do
      filter expr(role in [:admin, :super_admin])
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    create :register_with_password do
      description "Register a new user with email and password"
      accept [:email, :display_name, :tenant_id]

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 12
      end

      argument :password_confirmation, :string do
        allow_nil? false
        sensitive? true
      end

      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      change AshAuthentication.Strategy.Password.HashPasswordChange
      change AshAuthentication.GenerateTokenChange
    end

    update :update do
      accept [:display_name]
    end

    update :update_email do
      accept [:email]
    end

    update :update_role do
      accept [:role]
    end

    update :change_password do
      description "Change a user's password"
      require_atomic? false

      argument :current_password, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 12
      end

      argument :password_confirmation, :string do
        allow_nil? false
        sensitive? true
      end

      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      change fn changeset, _context ->
        current_password = Ash.Changeset.get_argument(changeset, :current_password)
        user = changeset.data

        if Bcrypt.verify_pass(current_password, user.hashed_password) do
          changeset
        else
          Ash.Changeset.add_error(changeset, field: :current_password, message: "is incorrect")
        end
      end

      change AshAuthentication.Strategy.Password.HashPasswordChange
    end
  end

  calculations do
    calculate :confirmed?, :boolean, expr(not is_nil(confirmed_at))

    calculate :initials, :string, expr(
      if is_nil(display_name) do
        fragment("UPPER(LEFT(?, 2))", email)
      else
        fragment("UPPER(LEFT(?, 1)) || UPPER(LEFT(SPLIT_PART(?, ' ', 2), 1))", display_name, display_name)
      end
    )
  end

  code_interface do
    define :get_by_email, action: :by_email, args: [:email]
    define :get_by_email_and_tenant, action: :by_email_and_tenant, args: [:email, :tenant_id]
  end

  policies do
    # Allow authentication actions without an actor
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Users can read themselves
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))
    end

    # Users in same tenant can read each other (for assignment UIs, etc.)
    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    # Registration is allowed without an actor (public action)
    policy action(:register_with_password) do
      authorize_if always()
    end

    # Users can update their own non-role fields
    policy action(:update) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_email) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:change_password) do
      authorize_if expr(id == ^actor(:id))
    end

    # Only admins can change roles
    policy action(:update_role) do
      authorize_if expr(tenant_id == ^actor(:tenant_id) and ^actor(:role) == :admin)
    end
  end
end
