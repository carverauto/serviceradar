defmodule ServiceRadar.Identity.UserGroupMembership do
  @moduledoc """
  Membership row for a reusable identity user group.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "identity.user_groups.view"}
  @manage_check {ActorHasPermission, permission: "identity.user_groups.manage"}
  @fields [:group_id, :user_id, :role, :metadata, :source]

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
    define :create_membership, action: :create
    define :update_membership, action: :update
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @fields
      upsert? true
      upsert_identity :unique_group_user
      upsert_fields [:role, :metadata, :source, :updated_at]
    end

    update :update do
      accept [:role, :metadata]
    end

    read :by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission(:read, @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
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
