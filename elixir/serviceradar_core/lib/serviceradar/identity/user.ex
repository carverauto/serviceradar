defmodule ServiceRadar.Identity.User do
  @moduledoc """
  User resource for authentication and authorization.

  Maps to the instance-scoped `ng_users` table.

  ## Roles

  - `:viewer` - Read-only access to instance data
  - `:operator` - Can create and modify resources
  - `:admin` - Full instance management including user management

  ## Authentication

  Users can authenticate via:
  - Password (with bcrypt hashing)
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
        registration_enabled? false

        resettable do
          sender ServiceRadar.Identity.Senders.SendPasswordResetEmail
        end
      end
    end

    add_ons do
      confirmation :confirm_email do
        monitor_fields [:email]
        require_interaction? true
        sender ServiceRadar.Identity.Senders.SendConfirmationEmail
        # Auto-confirm for these actions:
        # - update_email: Uses token-based verification in the Accounts context
        auto_confirm_actions [:update_email]
      end
    end
  end

  code_interface do
    define :get_by_email, action: :by_email, args: [:email]
  end

  actions do
    defaults [:read]

    read :by_email do
      argument :email, :ci_string, allow_nil?: false
      get? true
      filter expr(email == ^arg(:email))
    end

    read :admins do
      filter expr(role == :admin)
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    create :register_with_password do
      description "Register a new user with email and password"
      accept [:email, :display_name]

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

      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      change AshAuthentication.Strategy.Password.HashPasswordChange
      change AshAuthentication.GenerateTokenChange
    end

    update :update do
      accept [:display_name]
    end

    update :update_email do
      accept [:email]
      # Mark email as confirmed since this action is called after token-based
      # verification in the Accounts context
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
    end

    update :update_role do
      accept [:role]
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

    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Users can read themselves or admins can read any user
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Registration is restricted to system/admin actors (bootstrap or admin workflow).
    policy action(:register_with_password) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :system)
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
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  changes do
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
      constraints one_of: [:viewer, :operator, :admin]
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

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
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
    # Email identity required by AshAuthentication for password strategies.
    # Email uniqueness is enforced per instance schema.
    identity :email, [:email]
  end
end
