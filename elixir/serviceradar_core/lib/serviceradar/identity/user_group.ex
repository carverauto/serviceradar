defmodule ServiceRadar.Identity.UserGroup do
  @moduledoc """
  Reusable user group for access grants across ServiceRadar features.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "identity.user_groups.view"}
  @manage_check {ActorHasPermission, permission: "identity.user_groups.manage"}
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
    defaults [:read, :destroy]

    create :create do
      accept @fields
    end

    update :update do
      accept @fields -- [:owner_id]
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
