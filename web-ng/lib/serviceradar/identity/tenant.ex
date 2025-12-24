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
    extensions: []

  postgres do
    table "tenants"
    repo ServiceRadarWebNG.Repo
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

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_slug, [:slug]
  end

  relationships do
    has_many :users, ServiceRadar.Identity.User
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
  end

  calculations do
    calculate :user_count, :integer, expr(count(users))

    calculate :display_status, :string, expr(
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

  policies do
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
end
