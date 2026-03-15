defmodule ServiceRadar.Identity.RoleProfile do
  @moduledoc """
  Role profiles define permission sets for RBAC.

  Built-in profiles (admin/operator/viewer) are system profiles and are clonable
  but not editable by admins.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Identity.Changes.DisallowSystemProfileEdit
  alias ServiceRadar.Identity.Changes.InvalidateRbacCache
  alias ServiceRadar.Identity.Validations.PermissionKeys

  require Ash.Query

  @rbac_manage_permission ServiceRadar.Identity.Constants.rbac_manage_permission()
  @rbac_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                      permission: @rbac_manage_permission}
  @profile_fields [:name, :description, :permissions]
  @system_profile_fields [:system_name | @profile_fields]

  postgres do
    table "role_profiles"
    repo ServiceRadar.Repo
    schema "platform"
    identity_wheres_to_sql unique_system_name: "system_name IS NOT NULL"
  end

  code_interface do
    define :list, action: :read
    define :get_by_id, action: :get_by_id, args: [:id]
    define :create_profile, action: :create
    define :create_system_profile, action: :create_system
    define :update_profile, action: :update
    define :delete_profile, action: :destroy
  end

  actions do
    defaults [:read]

    read :get_by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :get_by_system_name do
      argument :system_name, :string, allow_nil?: false
      filter expr(system_name == ^arg(:system_name))
    end

    create :create do
      accept @profile_fields
      change set_attribute(:system, false)
      change set_attribute(:system_name, nil)
      validate PermissionKeys
      change InvalidateRbacCache
    end

    create :create_system do
      accept @system_profile_fields
      change set_attribute(:system, true)
      validate PermissionKeys
      change InvalidateRbacCache
    end

    update :update do
      accept @profile_fields
      change DisallowSystemProfileEdit
      validate PermissionKeys
      change InvalidateRbacCache
    end

    destroy :destroy do
      change DisallowSystemProfileEdit
      change InvalidateRbacCache
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    read_with_permission(@rbac_manage_check)

    action_with_permission([:create, :create_system, :update, :destroy], @rbac_manage_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :system_name, :string do
      allow_nil? true
      public? false
      description "System identifier for built-in profiles"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable profile name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Optional description of the profile"
    end

    attribute :permissions, {:array, :string} do
      allow_nil? false
      default []
      public? true
      description "List of permission keys assigned to this profile"
    end

    attribute :system, :boolean do
      allow_nil? false
      default false
      public? false
      description "Whether this is a built-in system profile"
    end

    timestamps()
  end

  identities do
    identity :unique_name, [:name]
    identity :unique_system_name, [:system_name], where: expr(not is_nil(system_name))
  end

  # NOTE: We intentionally implement this explicitly rather than using Ash's
  # code_interface for a get-style action. Treating `system_name` like a primary key
  # can lead to confusing NotFound errors when it is cast as a UUID id.
  def get_by_system_name(system_name, opts \\ []) when is_binary(system_name) do
    __MODULE__
    |> Ash.Query.for_read(:get_by_system_name, %{system_name: system_name})
    |> Ash.read_one(opts)
  end
end
