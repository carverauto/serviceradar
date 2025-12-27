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
    attributes([:contact_email, :contact_name])
    decrypt_by_default([:contact_email, :contact_name])
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

    create :create do
      accept [:name, :slug, :contact_email, :contact_name, :plan, :max_devices, :max_users]
      change ServiceRadar.Identity.Changes.GenerateSlug
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
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
