defmodule ServiceRadar.Identity.TenantMembership do
  @moduledoc """
  Join resource between Users and Tenants with role-based access.

  This allows users to belong to multiple tenants with different roles per tenant.
  Following the pattern from TaskManager.Organizations.Membership.

  ## Roles

  - `:owner` - Full control, can manage tenant settings and memberships
  - `:admin` - Can manage resources and invite members
  - `:member` - Standard access to tenant resources
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "tenant_memberships"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    # Allow querying without tenant context (e.g., to list all memberships for a user)
    global? true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:role, :user_id, :tenant_id]
    end

    create :create_owner do
      description "Create an owner membership for a new tenant"
      accept [:user_id, :tenant_id]
      change set_attribute(:role, :owner)
    end

    update :update do
      accept [:role]
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Allow reading memberships for own tenant
    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    # Owners and admins can create memberships for their tenant
    policy action_type(:create) do
      authorize_if expr(tenant_id == ^actor(:tenant_id) and ^actor(:role) in [:owner, :admin])
    end

    # Only owners can update memberships
    policy action_type(:update) do
      authorize_if expr(tenant_id == ^actor(:tenant_id) and ^actor(:role) == :owner)
    end

    # Only owners can delete memberships (except themselves)
    policy action_type(:destroy) do
      authorize_if expr(
                     tenant_id == ^actor(:tenant_id) and ^actor(:role) == :owner and
                       user_id != ^actor(:id)
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      constraints one_of: [:owner, :admin, :member]
      default :member
      allow_nil? false
      public? true
      description "Role within this tenant"
    end

    attribute :joined_at, :utc_datetime do
      default &DateTime.utc_now/0
      allow_nil? false
      public? true
      description "When the user joined this tenant"
    end

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
    end

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tenant, ServiceRadar.Identity.Tenant do
      source_attribute :tenant_id
      allow_nil? false
    end

    belongs_to :user, ServiceRadar.Identity.User do
      source_attribute :user_id
      allow_nil? false
    end
  end

  identities do
    identity :unique_membership, [:user_id, :tenant_id]
  end
end
