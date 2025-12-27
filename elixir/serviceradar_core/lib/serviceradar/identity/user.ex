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
    repo ServiceRadar.Repo
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
        registration_enabled? true
        require_interaction? true
        lookup_action_name :by_email
        sender ServiceRadar.Identity.Senders.SendMagicLinkEmail
        # Disable prevent_hijacking since we have auto_confirm_actions for magic link
        # and the magic link itself proves email ownership
        prevent_hijacking? false
      end
    end

    add_ons do
      confirmation :confirm_email do
        monitor_fields [:email]
        require_interaction? true
        sender ServiceRadar.Identity.Senders.SendConfirmationEmail
        # Auto-confirm for these actions:
        # - sign_in_with_magic_link: Magic link verifies email ownership
        # - update_email: Uses token-based verification in the Accounts context
        auto_confirm_actions [:sign_in_with_magic_link, :update_email]
        # Disable prevent_hijacking for upserts since magic link auto-confirms
        # and proves email ownership. This allows magic link sign-in/registration
        # to work for new and unconfirmed users.
        prevent_hijacking? false
      end
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  code_interface do
    define :get_by_email, action: :by_email, args: [:email]
    define :get_by_email_and_tenant, action: :by_email_and_tenant, args: [:email, :tenant_id]
  end

  actions do
    defaults [:read]

    create :create do
      description "Register a new user with email only (magic link flow)"
      accept [:email, :display_name, :tenant_id, :role]
      change ServiceRadar.Identity.Changes.AssignDefaultTenant
      primary? true
    end

    create :sign_in_with_magic_link do
      description "Sign in or register a user with magic link."

      argument :token, :string do
        description "The token from the magic link that was sent to the user"
        allow_nil? false
      end

      argument :remember_me, :boolean do
        description "Whether to generate a remember me token"
        allow_nil? true
      end

      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email]

      change ServiceRadar.Identity.Changes.AssignDefaultTenant
      change AshAuthentication.Strategy.MagicLink.SignInChange

      change {AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenChange,
              strategy_name: :remember_me}

      metadata :token, :string do
        allow_nil? false
      end
    end

    action :request_magic_link do
      argument :email, :ci_string do
        allow_nil? false
      end

      run AshAuthentication.Strategy.MagicLink.Request
    end

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

      change ServiceRadar.Identity.Changes.AssignDefaultTenant

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
      require_atomic? false
    end

    update :update_email do
      accept [:email]
      require_atomic? false
      # Mark email as confirmed since this action is called after token-based
      # verification in the Accounts context
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
    end

    update :update_role do
      accept [:role]
      require_atomic? false
    end

    update :change_password do
      description "Change a user's password"
      require_atomic? false

      argument :current_password, :string do
        # Allow nil here - the change block handles validation based on whether user has a password
        allow_nil? true
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

      # Validate password confirmation matches
      validate fn changeset, _context ->
        password = Ash.Changeset.get_argument(changeset, :password)
        confirmation = Ash.Changeset.get_argument(changeset, :password_confirmation)

        if password == confirmation do
          :ok
        else
          {:error, field: :password_confirmation, message: "does not match password"}
        end
      end

      # Validate current password is correct
      change fn changeset, _context ->
        current_password = Ash.Changeset.get_argument(changeset, :current_password)
        user = changeset.data

        cond do
          # User has no password set - allow password creation without current_password
          is_nil(user.hashed_password) or user.hashed_password == "" ->
            if current_password && current_password != "" do
              Ash.Changeset.add_error(changeset,
                field: :current_password,
                message: "you don't have a password set"
              )
            else
              changeset
            end

          # User has password but current_password not provided - require it
          is_nil(current_password) or current_password == "" ->
            Ash.Changeset.add_error(changeset,
              field: :current_password,
              message: "is required to change password"
            )

          # Verify current password
          Bcrypt.verify_pass(current_password, user.hashed_password) ->
            changeset

          true ->
            Ash.Changeset.add_error(changeset, field: :current_password, message: "is incorrect")
        end
      end

      # Hash the new password
      change fn changeset, _context ->
        password = Ash.Changeset.get_argument(changeset, :password)

        if password do
          hashed = Bcrypt.hash_pwd_salt(password)
          Ash.Changeset.force_change_attribute(changeset, :hashed_password, hashed)
        else
          changeset
        end
      end
    end
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

    # Users can read themselves OR other users in the same tenant
    # Combined into one policy to ensure proper OR behavior
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id) or tenant_id == ^actor(:tenant_id))
    end

    # Registration is allowed without an actor (public action)
    policy action(:register_with_password) do
      authorize_if always()
    end

    # Magic link registration uses the primary create action
    policy action(:create) do
      authorize_if always()
    end

    policy action(:request_magic_link) do
      authorize_if always()
    end

    policy action(:sign_in_with_magic_link) do
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

  changes do
    # SECURITY: tenant_id is IMMUTABLE after creation
    # This is a critical multi-tenancy security control - defense in depth
    # Uses before_action to run AFTER all changes have been applied to the changeset
    change before_action(fn changeset, _context ->
             if changeset.action_type == :update do
               # Check if tenant_id is in the changes map
               case Map.get(changeset.attributes, :tenant_id) do
                 nil ->
                   # Not being changed, that's fine
                   changeset

                 _new_value ->
                   # Someone is trying to change tenant_id - block it
                   Ash.Changeset.add_error(changeset,
                     field: :tenant_id,
                     message: "cannot be changed - tenant assignment is permanent"
                   )
               end
             else
               changeset
             end
           end)
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
      description "User email address (unique per tenant)"
      constraints match: ~r/^[^\s]+@[^\s]+$/
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

    attribute :authenticated_at, :utc_datetime do
      public? true
      description "When the user last authenticated (for sudo mode)"
    end

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? true
      description "Owning tenant ID - immutable after creation (see validations)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    # Primary tenant (for backwards compatibility and default context)
    belongs_to :tenant, ServiceRadar.Identity.Tenant do
      allow_nil? false
      attribute_type :uuid
      source_attribute :tenant_id
    end

    # Memberships allow users to belong to multiple tenants with different roles
    has_many :memberships, ServiceRadar.Identity.TenantMembership do
      source_attribute :id
      destination_attribute :user_id
      public? true
    end

    # All tenants the user belongs to via memberships
    many_to_many :tenants, ServiceRadar.Identity.Tenant do
      through ServiceRadar.Identity.TenantMembership
      source_attribute_on_join_resource :user_id
      destination_attribute_on_join_resource :tenant_id
      public? true
    end
  end

  calculations do
    calculate :confirmed?, :boolean, expr(not is_nil(confirmed_at))

    calculate :initials,
              :string,
              expr(
                if is_nil(display_name) do
                  fragment("UPPER(LEFT(?, 2))", email)
                else
                  fragment(
                    "UPPER(LEFT(?, 1)) || UPPER(LEFT(SPLIT_PART(?, ' ', 2), 1))",
                    display_name,
                    display_name
                  )
                end
              )
  end

  identities do
    identity :unique_email_per_tenant, [:tenant_id, :email]
    identity :unique_email, [:email]
  end
end
