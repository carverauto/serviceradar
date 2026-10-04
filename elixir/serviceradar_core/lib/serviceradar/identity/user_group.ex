defmodule ServiceRadar.Identity.UserGroup do
  @moduledoc """
  Reusable user group for access grants across ServiceRadar features.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Identity.Changes.RequirePrivilegeBoundary
  alias ServiceRadar.Identity.Homepage
  alias ServiceRadar.Identity.Validations.HomepagePreference
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  Code.ensure_compiled!(Homepage)

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

    check_constraints do
      check_constraint :homepage_kind, "user_groups_homepage_preference_check",
        check: Homepage.preference_check_sql(),
        message: "must be a platform page or a dashboard id"
    end
  end

  code_interface do
    define :list, action: :read
    define :create_group, action: :create
    define :update_group, action: :update
    define :update_homepage_preference, action: :update_homepage_preference
  end

  actions do
    defaults [:read]

    create :create do
      accept @fields
    end

    update :update do
      accept @fields -- [:owner_id]
    end

    update :update_homepage_preference do
      description "Set or clear this group's homepage without changing its name or membership"
      accept []

      argument :homepage_kind, :atom do
        allow_nil? true
        constraints one_of: [:platform, :dashboards, :authored, :package]
      end

      argument :homepage_target, :string do
        allow_nil? true
        constraints max_length: 200, allow_empty?: true
      end

      change set_attribute(:homepage_kind, arg(:homepage_kind))
      change set_attribute(:homepage_target, arg(:homepage_target))
      validate HomepagePreference
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
      [
        :create,
        :update,
        :update_homepage_preference,
        :assign_role_profile,
        :clear_role_profile,
        :destroy
      ],
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

    attribute :homepage_kind, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:platform, :dashboards, :authored, :package]

      description """
      Homepage for members who have not chosen their own. Null means this group
      does not set one. Choosing a dashboard does not share that dashboard.
      """
    end

    attribute :homepage_target, :string do
      allow_nil? true
      public? true
      description "Authored dashboard id or package route slug. Null for every other kind."
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
