defmodule ServiceRadar.Identity.User do
  @moduledoc """
  User resource for authentication and authorization.

  Maps to the instance-scoped `ng_users` table.

  ## Roles

  - `:viewer` - Read-only access to instance data
  - `:helpdesk` - Read-only access plus alert response capabilities
  - `:operator` - Can create and modify resources
  - `:admin` - Full instance management including user management

  ## Authentication

  Users can authenticate via:
  - Password (with bcrypt hashing)
  - OIDC (Google, Azure AD, Okta)
  - SAML 2.0 (enterprise IdPs)
  - Gateway JWT (Kong, Ambassador)

  Authentication is handled by Guardian + Ueberauth, not AshAuthentication.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.Identity.UserNotifier],
    authorizers: [Ash.Policy.Authorizer]

  @allowed_roles ServiceRadar.Identity.Constants.allowed_roles()
  @auth_manage_permission ServiceRadar.Identity.Constants.auth_manage_permission()
  @auth_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                      permission: @auth_manage_permission}
  @user_admin_fields [:email, :display_name, :role, :role_profile_id]
  @user_profile_fields [:email, :display_name]
  @display_name_fields [:display_name]
  @email_fields [:email]
  @role_fields [:role]
  @role_profile_fields [:role_profile_id]

  postgres do
    table "ng_users"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_email, action: :by_email, args: [:email]
    define :get_by_id, action: :by_id, args: [:id]
    define :authenticate, action: :authenticate, args: [:email, :password]
    define :register_with_password
    define :provision_sso_user
    define :update
    define :change_password
    define :record_authentication
    define :record_login
    define :deactivate
    define :reactivate
    define :update_role
    define :update_role_profile, action: :update_role_profile
    define :admin_set_password, action: :admin_set_password
  end

  actions do
    defaults [:read]

    read :by_email do
      argument :email, :ci_string, allow_nil?: false
      get? true
      filter expr(email == ^arg(:email))
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :admins do
      filter expr(role == :admin and status == :active)
    end

    # Password authentication action
    # Returns user if credentials valid, error otherwise
    read :authenticate do
      description "Authenticate a user with email and password"
      argument :email, :ci_string, allow_nil?: false
      argument :password, :string, allow_nil?: false, sensitive?: true
      get? true
      filter expr(email == ^arg(:email) and status == :active)

      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, results ->
          case results do
            [user] ->
              password = Ash.Query.get_argument(query, :password)

              if verify_password(password, user.hashed_password) do
                {:ok, [user]}
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
      description "Create a new user (admin or system use)"
      accept @user_admin_fields

      argument :password, :string do
        allow_nil? true
        sensitive? true
        constraints min_length: 12
      end

      change {ServiceRadar.Identity.Changes.HashPassword, force?: true}
    end

    create :register_with_password do
      description "Register a new user with email and password"
      accept @user_profile_fields

      change ServiceRadar.Identity.Changes.AssignFirstUserRole

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 12
      end

      argument :password_confirmation, :string do
        allow_nil? false
        sensitive? true
      end

      validate ServiceRadar.Identity.Validations.PasswordConfirmationMatches

      change {ServiceRadar.Identity.Changes.HashPassword, force?: true}
    end

    # JIT provisioning for SSO users
    create :provision_sso_user do
      description "Create a user from SSO claims (JIT provisioning)"
      accept @user_profile_fields

      argument :role, :atom do
        allow_nil? true
        default :viewer
        constraints one_of: @allowed_roles
      end

      argument :external_id, :string do
        allow_nil? false
        description "IdP subject identifier"
      end

      argument :provider, :atom do
        allow_nil? false
        constraints one_of: [:oidc, :saml, :gateway]
      end

      # Set default role and mark as confirmed (SSO = verified email)
      change set_attribute(:role, arg(:role))
      change set_attribute(:status, :active)
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        external_id = Ash.Changeset.get_argument(changeset, :external_id)
        Ash.Changeset.force_change_attribute(changeset, :external_id, external_id)
      end
    end

    update :update do
      accept @display_name_fields
    end

    update :update_email do
      accept @email_fields
      require_atomic? false

      argument :current_password, :string do
        allow_nil? false
        sensitive? true
      end

      validate {ServiceRadar.Identity.Validations.CurrentPassword, required_message: "is required"}

      # Mark email as confirmed since this action is called after token-based
      # verification in the Accounts context
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
    end

    update :update_role do
      accept @role_fields
      require_atomic? false
      change ServiceRadar.Identity.Changes.DisallowLastAdminLockout
      change ServiceRadar.Identity.Changes.InvalidateUserRbacCache
    end

    update :update_role_profile do
      accept @role_profile_fields
      change ServiceRadar.Identity.Changes.InvalidateUserRbacCache
    end

    update :change_password do
      description "Change a user's password"
      # Non-atomic: validates current password against stored hash
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

      validate ServiceRadar.Identity.Validations.PasswordConfirmationMatches

      validate {ServiceRadar.Identity.Validations.CurrentPassword,
                required_message: "is required to change password",
                no_password_message: "you don't have a password set"}

      change {ServiceRadar.Identity.Changes.HashPassword, force?: true}
    end

    update :admin_set_password do
      description "Set a user's password without requiring the current password (admin-only flow)"
      require_atomic? false

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 12
      end

      change {ServiceRadar.Identity.Changes.HashPassword, force?: true}
    end

    update :record_authentication do
      description "Record authentication timestamp for sudo mode"
      change set_attribute(:authenticated_at, &DateTime.utc_now/0)
    end

    update :record_login do
      description "Record user login timestamp and method"

      argument :auth_method, :atom do
        allow_nil? false
        constraints one_of: [:password, :oidc, :saml, :gateway, :api_token, :oauth_client]
      end

      change set_attribute(:last_login_at, &DateTime.utc_now/0)
      change set_attribute(:last_auth_method, arg(:auth_method))
    end

    update :deactivate do
      description "Deactivate a user account and revoke access"
      require_atomic? false
      change ServiceRadar.Identity.Changes.DisallowLastAdminLockout
      change set_attribute(:status, :inactive)
    end

    update :reactivate do
      description "Reactivate a user account"
      change set_attribute(:status, :active)
    end
  end

  policies do
    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Public reads used by authentication flows (no actor available yet)
    policy action([:by_email, :authenticate]) do
      authorize_if ServiceRadar.Policies.Checks.ActorIsNil

      authorize_if @auth_manage_check
    end

    # Read access:
    # - Admins (settings.auth.manage) can read any user
    # - Users can read themselves
    policy action_type(:read) do
      authorize_if @auth_manage_check

      authorize_if expr(id == ^actor(:id))
    end

    # Public registration (no actor available)
    policy action(:register_with_password) do
      authorize_if ServiceRadar.Policies.Checks.ActorIsNil
    end

    # Admin-managed user creation
    policy action(:create) do
      authorize_if @auth_manage_check
    end

    # JIT provisioning is performed as a SystemActor in the web layer.
    # Allow admins to use it intentionally; deny regular users.
    policy action(:provision_sso_user) do
      authorize_if @auth_manage_check
    end

    # Self-service updates and audit markers
    policy action([
             :update,
             :update_email,
             :change_password,
             :record_authentication,
             :record_login
           ]) do
      authorize_if expr(id == ^actor(:id))

      authorize_if @auth_manage_check
    end

    # Admin-only user management
    policy action([
             :update_role,
             :update_role_profile,
           :admin_set_password,
           :deactivate,
           :reactivate
         ]) do
      authorize_if @auth_manage_check
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
      description "User email address (unique within the instance)"
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
      constraints one_of: @allowed_roles
      description "User's role for authorization"
    end

    attribute :role_profile_id, :uuid do
      allow_nil? true
      public? true
      description "Role profile assignment for RBAC"
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      public? true
      constraints one_of: [:active, :inactive]
      description "User account status"
    end

    attribute :external_id, :string do
      public? false
      description "External IdP subject identifier (for SSO users)"
    end

    attribute :confirmed_at, :utc_datetime do
      public? true
      description "When the user confirmed their email"
    end

    attribute :authenticated_at, :utc_datetime do
      public? true
      description "When the user last authenticated (for sudo mode)"
    end

    attribute :last_login_at, :utc_datetime do
      public? true
      description "When the user last logged in"
    end

    attribute :last_auth_method, :atom do
      public? true
      constraints one_of: [:password, :oidc, :saml, :gateway, :api_token, :oauth_client]
      description "Last authentication method used by the user"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :role_profile, ServiceRadar.Identity.RoleProfile do
      allow_nil? true
      attribute_writable? true
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
    # Email uniqueness is enforced per instance schema
    identity :email, [:email]
  end

  # Helper function for password verification
  defp verify_password(nil, _hash), do: false
  defp verify_password(_password, nil), do: false
  defp verify_password(_password, ""), do: false
  defp verify_password(password, hash), do: Bcrypt.verify_pass(password, hash)
end
