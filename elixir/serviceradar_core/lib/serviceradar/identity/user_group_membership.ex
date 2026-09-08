defmodule ServiceRadar.Identity.UserGroupMembership do
  @moduledoc """
  Membership row for a reusable identity user group.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Identity.Changes.RequirePrivilegeBoundary
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "identity.user_groups.view"}
  @manage_check {ActorHasPermission, permission: "identity.user_groups.manage"}
  postgres do
    table "user_group_memberships"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    references do
      reference :group, on_delete: :delete
      reference :user, on_delete: :delete
    end
  end

  code_interface do
    define :list, action: :read
    define :list_by_user, action: :by_user, args: [:user_id]
  end

  actions do
    defaults [:read]

    create :create_manual do
      accept [:group_id, :user_id, :role, :metadata]
      change set_attribute(:source, :manual)
      upsert? true
      upsert_identity :unique_group_user
      upsert_fields [:role, :metadata, :source, :updated_at]
      validate RequirePrivilegeBoundary
    end

    create :create_idp do
      accept [:group_id, :user_id, :metadata]
      change set_attribute(:source, :idp)
      upsert? true
      upsert_identity :unique_group_user
      upsert_condition expr(source == :idp)
      upsert_fields [:metadata, :updated_at]
      return_skipped_upsert? true
      validate RequirePrivilegeBoundary
    end

    destroy :destroy do
      validate RequirePrivilegeBoundary
    end

    read :by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :for_group_privilege_boundary do
      argument :group_id, :uuid, allow_nil?: false
      filter expr(group_id == ^arg(:group_id))
    end

    read :for_membership_privilege_boundary do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_user], @view_check)

    action_with_permission(
      [:for_group_privilege_boundary, :for_membership_privilege_boundary],
      @manage_check
    )

    action_type_with_permission([:create, :destroy], @manage_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :group_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      default :member
      constraints one_of: [:member, :manager]
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :manual
      constraints one_of: [:manual, :idp]

      description """
      Who created this membership. An identity provider may withdraw the
      memberships it created when a user leaves the mapped group, and must never
      withdraw one an operator added by hand -- the IdP knows nothing about
      those.
      """
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :group, ServiceRadar.Identity.UserGroup do
      allow_nil? false
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :group_id
    end

    belongs_to :user, ServiceRadar.Identity.User do
      allow_nil? false
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :user_id
    end
  end

  identities do
    identity :unique_group_user, [:group_id, :user_id]
  end
end
