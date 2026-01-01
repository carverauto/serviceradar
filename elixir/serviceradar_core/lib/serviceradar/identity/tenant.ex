defmodule ServiceRadar.Identity.Tenant do
  @moduledoc """
  Represents a tenant (organization) in the multi-tenant system.

  Tenants own users, devices, pollers, and all other tenant-scoped resources.
  Each tenant has isolated data with configurable plan limits.

  ## Statuses

  - `active` - Normal operating state
  - `suspended` - Billing issue or policy violation, read-only access
  - `pending` - Awaiting activation (e.g., email verification)
  - `deleted` - Soft deleted, retained for audit

  ## Plans

  - `free` - Basic tier with device/user limits
  - `pro` - Professional tier with higher limits
  - `enterprise` - Custom limits and features
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "tenants"
    repo ServiceRadar.Repo
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:contact_email, :contact_name, :nats_account_seed_ciphertext])
    decrypt_by_default([:contact_email, :contact_name])
    # Note: nats_account_seed_ciphertext is NOT decrypted by default for security
  end

  actions do
    defaults [:read]

    read :by_slug do
      argument :slug, :ci_string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :active do
      filter expr(status == :active)
    end

    read :for_nats_provisioning do
      @doc """
      Read tenants for NATS provisioning without loading encrypted fields.
      This avoids AshCloak decryption issues when encrypted columns are NULL.
      """
      prepare fn query, _context ->
        # Don't load any cloaked attributes to avoid decryption
        query
        |> Ash.Query.unload([:contact_email, :contact_name, :nats_account_seed_ciphertext])
      end
    end

    create :create do
      accept [:name, :slug, :contact_email, :contact_name, :plan, :max_devices, :max_users]
      change ServiceRadar.Identity.Changes.GenerateSlug
      change ServiceRadar.Identity.Changes.InitializeTenantInfrastructure
    end

    update :update do
      accept [:name, :contact_email, :contact_name, :settings]
    end

    update :upgrade_plan do
      accept [:plan, :max_devices, :max_users]
    end

    update :suspend do
      change set_attribute(:status, :suspended)
    end

    update :activate do
      change set_attribute(:status, :active)
    end

    update :soft_delete do
      change set_attribute(:status, :deleted)
    end

    update :set_nats_account do
      description "Set NATS account credentials after successful provisioning"
      accept []
      require_atomic? false

      argument :account_public_key, :string, allow_nil?: false
      argument :account_seed, :string, allow_nil?: false
      argument :account_jwt, :string, allow_nil?: false

      change fn changeset, _context ->
        account_seed = Ash.Changeset.get_argument(changeset, :account_seed)

        changeset
        |> Ash.Changeset.change_attribute(:nats_account_public_key, Ash.Changeset.get_argument(changeset, :account_public_key))
        # Use AshCloak.encrypt_and_set for encrypted attributes (the attribute is transformed to encrypted_*)
        |> AshCloak.encrypt_and_set(:nats_account_seed_ciphertext, account_seed)
        |> Ash.Changeset.change_attribute(:nats_account_jwt, Ash.Changeset.get_argument(changeset, :account_jwt))
        |> Ash.Changeset.change_attribute(:nats_account_status, :ready)
        |> Ash.Changeset.change_attribute(:nats_account_error, nil)
        |> Ash.Changeset.change_attribute(:nats_account_provisioned_at, DateTime.utc_now())
      end
    end

    update :set_nats_account_error do
      description "Record NATS account provisioning failure"
      accept []
      require_atomic? false

      argument :error_message, :string, allow_nil?: false

      change set_attribute(:nats_account_status, :error)
      change fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :nats_account_error,
          Ash.Changeset.get_argument(changeset, :error_message)
        )
      end
    end

    update :set_nats_account_pending do
      description "Mark NATS account provisioning as pending"
      accept []
      change set_attribute(:nats_account_status, :pending)
      change set_attribute(:nats_account_error, nil)
    end

    update :update_nats_account_jwt do
      description "Update NATS account JWT (after re-signing)"
      accept []
      require_atomic? false

      argument :account_jwt, :string, allow_nil?: false

      change fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :nats_account_jwt,
          Ash.Changeset.get_argument(changeset, :account_jwt)
        )
      end
    end

    update :clear_nats_account do
      description "Clear NATS account credentials (revoke/reset)"
      accept []
      require_atomic? false

      argument :reason, :string, allow_nil?: true

      change set_attribute(:nats_account_public_key, nil)
      change set_attribute(:nats_account_jwt, nil)
      change set_attribute(:nats_account_status, nil)
      change set_attribute(:nats_account_error, nil)
      change set_attribute(:nats_account_provisioned_at, nil)

      change fn changeset, _context ->
        AshCloak.encrypt_and_set(changeset, :nats_account_seed_ciphertext, nil)
      end
    end

    action :generate_ca, :struct do
      description """
      Generate a per-tenant Certificate Authority for edge component isolation.

      Creates an intermediate CA signed by the platform root CA. All edge
      components (pollers, agents, checkers) for this tenant will receive
      certificates signed by this CA, ensuring network-level tenant isolation.

      This action is idempotent - if an active CA already exists, it returns
      the existing CA.
      """

      constraints instance_of: ServiceRadar.Edge.TenantCA

      argument :tenant, :struct do
        constraints instance_of: ServiceRadar.Identity.Tenant
        allow_nil? false
        description "The tenant to generate CA for"
      end

      argument :validity_years, :integer do
        default 10
        description "CA validity in years"
      end

      argument :force_regenerate, :boolean do
        default false
        description "If true, revokes existing CA and generates new one"
      end

      run fn input, _context ->
        tenant = input.arguments.tenant
        validity_years = input.arguments.validity_years
        force_regenerate = input.arguments.force_regenerate

        # Check for existing active CA
        tenant_uuid = tenant.id

        existing_ca =
          ServiceRadar.Edge.TenantCA
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(tenant_id: tenant_uuid, status: :active)
          |> Ash.read_one!(authorize?: false)

        cond do
          existing_ca != nil and not force_regenerate ->
            # Return existing CA
            {:ok, existing_ca}

          existing_ca != nil and force_regenerate ->
            # Revoke existing and generate new
            {:ok, _} = Ash.update(existing_ca, %{},
              action: :revoke,
              arguments: %{reason: "Regenerated by admin"},
              authorize?: false
            )

            Ash.create(ServiceRadar.Edge.TenantCA, %{},
              action: :generate,
              arguments: %{tenant_id: tenant.id, validity_years: validity_years},
              authorize?: false
            )

          true ->
            # Generate new CA
            Ash.create(ServiceRadar.Edge.TenantCA, %{},
              action: :generate,
              arguments: %{tenant_id: tenant.id, validity_years: validity_years},
              authorize?: false
            )
        end
      end
    end

    create :register do
      description """
      Register a new tenant with an owner user.

      Creates the tenant, the owner user, and an owner membership in one transaction.
      This is the primary way to create new tenants during signup.
      """

      accept [:name, :slug]

      argument :owner, :map do
        description "Owner user information (email, password, password_confirmation, display_name)"
        allow_nil? false
      end

      change ServiceRadar.Identity.Changes.GenerateSlug
      change ServiceRadar.Identity.Changes.InitializeTenantInfrastructure

      change fn changeset, _ ->
        changeset
        |> Ash.Changeset.after_action(fn _changeset, tenant ->
          owner_params = Ash.Changeset.get_argument(changeset, :owner)

          user_params = %{
            email: owner_params["email"] || owner_params[:email],
            password: owner_params["password"] || owner_params[:password],
            password_confirmation:
              owner_params["password_confirmation"] || owner_params[:password_confirmation],
            display_name: owner_params["display_name"] || owner_params[:display_name],
            tenant_id: tenant.id,
            role: :admin
          }

          with {:ok, user} <-
                 Ash.create(ServiceRadar.Identity.User, user_params,
                   action: :register_with_password,
                   authorize?: false
                 ),
               {:ok, _membership} <-
                 Ash.create(
                   ServiceRadar.Identity.TenantMembership,
                   %{
                     user_id: user.id,
                     tenant_id: tenant.id,
                     role: :owner
                   },
                   tenant: tenant.id,
                   authorize?: false
                 ),
               {:ok, final_tenant} <- Ash.update(tenant, %{owner_id: user.id}, authorize?: false) do
            {:ok, final_tenant}
          else
            {:error, error} -> {:error, error}
          end
        end)
      end
    end
  end

  policies do
    # Allow public tenant registration (no actor required)
    bypass action(:register) do
      authorize_if always()
    end

    # Super admins can do anything
    bypass action_type(:read) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    bypass action_type(:create) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    bypass action_type(:update) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Regular users can only read their own tenant
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:tenant_id))
    end

    # Tenant admins can update their own tenant (limited fields)
    policy action(:update) do
      authorize_if expr(id == ^actor(:tenant_id) and ^actor(:role) == :admin)
    end

    # Only super_admins can generate/regenerate tenant CAs
    policy action(:generate_ca) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # NATS account actions are internal (system only, no actor)
    # These are called by Oban jobs with authorize?: false
    policy action(:set_nats_account) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action(:set_nats_account_error) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action(:set_nats_account_pending) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action(:update_nats_account_jwt) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action(:clear_nats_account) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable tenant name"
    end

    attribute :slug, :ci_string do
      allow_nil? false
      public? true
      description "URL-safe unique identifier"
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      public? true
      constraints one_of: [:active, :suspended, :pending, :deleted]
      description "Current tenant status"
    end

    attribute :settings, :map do
      default %{}
      public? true
      description "Tenant-specific configuration settings"
    end

    attribute :plan, :atom do
      default :free
      public? true
      constraints one_of: [:free, :pro, :enterprise]
      description "Billing plan tier"
    end

    attribute :max_devices, :integer do
      default 100
      public? true
      description "Maximum number of devices allowed"
    end

    attribute :max_users, :integer do
      default 5
      public? true
      description "Maximum number of users allowed"
    end

    attribute :contact_email, :string do
      public? true
      description "Primary contact email for the tenant"
    end

    attribute :contact_name, :string do
      public? true
      description "Primary contact name"
    end

    attribute :owner_id, :uuid do
      allow_nil? true
      public? true
      description "Owner user ID (set during registration)"
    end

    # NATS Account fields for multi-tenant isolation
    attribute :nats_account_public_key, :string do
      allow_nil? true
      public? false
      description "NATS account public key (starts with 'A')"
    end

    attribute :nats_account_seed_ciphertext, :binary do
      allow_nil? true
      public? false
      description "Encrypted NATS account seed (starts with 'SA' when decrypted)"
    end

    attribute :nats_account_jwt, :string do
      allow_nil? true
      public? false
      constraints max_length: 8192
      description "Signed NATS account JWT"
    end

    attribute :nats_account_status, :atom do
      allow_nil? true
      public? false
      constraints one_of: [:pending, :ready, :error]
      description "NATS account provisioning status"
    end

    attribute :nats_account_error, :string do
      allow_nil? true
      public? false
      description "Error message if NATS account provisioning failed"
    end

    attribute :nats_account_provisioned_at, :utc_datetime_usec do
      allow_nil? true
      public? false
      description "When the NATS account was successfully provisioned"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    # Direct user relationship via tenant_id (for backwards compatibility)
    has_many :users, ServiceRadar.Identity.User

    # Owner of the tenant (set during registration)
    belongs_to :owner, ServiceRadar.Identity.User do
      source_attribute :owner_id
      public? true
      allow_nil? true
    end

    # Memberships for role-based access
    has_many :memberships, ServiceRadar.Identity.TenantMembership do
      source_attribute :id
      destination_attribute :tenant_id
      public? true
    end

    # All members via memberships
    many_to_many :members, ServiceRadar.Identity.User do
      through ServiceRadar.Identity.TenantMembership
      source_attribute_on_join_resource :tenant_id
      destination_attribute_on_join_resource :user_id
      public? true
    end

    # Per-tenant certificate authorities for edge isolation
    has_many :certificate_authorities, ServiceRadar.Edge.TenantCA do
      source_attribute :id
      destination_attribute :tenant_id
      public? true
    end

    # Active CA for this tenant (used for generating new edge certs)
    has_one :active_ca, ServiceRadar.Edge.TenantCA do
      source_attribute :id
      destination_attribute :tenant_id
      filter expr(status == :active)
      public? true
    end
  end

  calculations do
    calculate :user_count, :integer, expr(count(users))

    calculate :display_status,
              :string,
              expr(
                if status == :active do
                  "Active"
                else
                  if status == :suspended do
                    "Suspended"
                  else
                    if status == :pending do
                      "Pending"
                    else
                      "Deleted"
                    end
                  end
                end
              )

    calculate :nats_account_ready?,
              :boolean,
              expr(nats_account_status == :ready and not is_nil(nats_account_jwt))
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
