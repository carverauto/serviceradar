defmodule ServiceRadar.Identity.UserGroup do
  @moduledoc """
  Reusable user group for access grants across ServiceRadar features.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Identity.Changes.RequirePrivilegeBoundary
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "identity.user_groups.view"}
  @manage_check {ActorHasPermission, permission: "identity.user_groups.manage"}
  @rbac_manage_check {ActorHasPermission, permission: "settings.rbac.manage"}
  @fields [:name, :description, :owner_id, :metadata]

  postgres do
    table "user_groups"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    references do
      reference :owner, on_delete: :nilify
      reference :role_profile, on_delete: :restrict
    end
  end

  code_interface do
    define :list, action: :read
    define :create_group, action: :create
    define :update_group, action: :update
  end

  actions do
    defaults [:read]

    create :create do
      accept @fields
    end

    update :update do
      accept @fields -- [:owner_id]
    end

    read :for_privilege_boundary do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_role_profile_boundary do
      argument :role_profile_id, :uuid, allow_nil?: false
      filter expr(role_profile_id == ^arg(:role_profile_id))
    end

    update :assign_role_profile do
      accept [:role_profile_id]
      validate RequirePrivilegeBoundary
    end

    update :clear_role_profile do
      accept []
      change set_attribute(:role_profile_id, nil)
      validate RequirePrivilegeBoundary
    end

    update :clear_role_profile_for_boundary do
      accept []
      change set_attribute(:role_profile_id, nil)
      validate RequirePrivilegeBoundary
    end

    destroy :destroy do
      validate RequirePrivilegeBoundary
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission(:read, @view_check)
    action_with_permission(:for_privilege_boundary, @manage_check)
    action_with_permission(:for_role_profile_boundary, @rbac_manage_check)

    action_with_permission(
      [:create, :update, :assign_role_profile, :clear_role_profile, :destroy],
      @manage_check
    )

    action_with_permission([:assign_role_profile, :clear_role_profile], @rbac_manage_check)
    action_with_permission(:clear_role_profile_for_boundary, @rbac_manage_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :owner_id, :uuid do
      public? true
    end

    attribute :role_profile_id, :uuid do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :owner, ServiceRadar.Identity.User do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :owner_id
    end

    belongs_to :role_profile, ServiceRadar.Identity.RoleProfile do
      public? true
      define_attribute? false
      source_attribute :role_profile_id
    end

    has_many :memberships, ServiceRadar.Identity.UserGroupMembership do
      destination_attribute :group_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
