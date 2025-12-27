defmodule ServiceRadar.Inventory.DeviceGroup do
  @moduledoc """
  Device group resource for organizing devices.

  Groups provide a way to organize devices into logical categories
  for management, reporting, and policy application.

  ## OCSF Alignment

  Aligns with OCSF Group object attributes:
  - `name` - Group name
  - `desc` - Group description
  - `type` - Group type classification
  - `uid` - Unique identifier

  ## Group Types

  - `location` - Geographic or physical location grouping
  - `department` - Organizational department
  - `environment` - Environment classification (prod, staging, dev)
  - `function` - Functional role (web servers, databases, etc.)
  - `custom` - User-defined grouping
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "device_groups"
    repo ServiceRadar.Repo
  end

  json_api do
    type "device-group"

    routes do
      base "/device-groups"

      get :by_id
      index :read
      post :create
      patch :update
      delete :destroy
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? false
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_type, action: :by_type, args: [:type]
    define :list_root_groups, action: :root_groups
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_type do
      argument :type, :atom, allow_nil?: false
      filter expr(type == ^arg(:type))
    end

    read :root_groups do
      description "Groups with no parent"
      filter expr(is_nil(parent_id))
    end

    create :create do
      accept [:name, :desc, :type, :parent_id, :metadata]
    end

    update :update do
      accept [:name, :desc, :type, :parent_id, :metadata]
    end

    update :increment_count do
      change atomic_update(:device_count, expr(device_count + 1))
    end

    update :decrement_count do
      change atomic_update(:device_count, expr(device_count - 1))
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # TENANT ISOLATION: Groups are organizational structures within a tenant

    # Read access: Authenticated users in same tenant
    policy action_type(:read) do
      authorize_if expr(
                     ^actor(:role) in [:viewer, :operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    # Create groups: Operators/admins in same tenant
    policy action(:create) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    # Update groups: Operators/admins in same tenant
    policy action([:update, :increment_count, :decrement_count]) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    # Delete groups: Admins only
    policy action(:destroy) do
      authorize_if expr(
                     ^actor(:role) == :admin and
                       tenant_id == ^actor(:tenant_id)
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
      description "Group display name"
    end

    attribute :desc, :string do
      public? true
      description "Group description"
    end

    attribute :type, :atom do
      default :custom
      public? true
      constraints one_of: [:location, :department, :environment, :function, :custom]
      description "Group type classification"
    end

    attribute :parent_id, :uuid do
      public? true
      description "Parent group ID for hierarchical grouping"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    attribute :device_count, :integer do
      default 0
      public? true
      description "Number of devices in this group"
    end

    create_timestamp :created_at
    update_timestamp :updated_at

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this group belongs to"
    end
  end

  relationships do
    has_many :devices, ServiceRadar.Inventory.Device do
      destination_attribute :group_id
      public? true
      description "Devices in this group"
    end

    belongs_to :parent, __MODULE__ do
      source_attribute :parent_id
      destination_attribute :id
      allow_nil? true
      public? true
      description "Parent group for hierarchical organization"
    end

    has_many :children, __MODULE__ do
      source_attribute :id
      destination_attribute :parent_id
      public? true
      description "Child groups"
    end
  end

  calculations do
    calculate :display_name,
              :string,
              expr(
                if not is_nil(desc) and desc != "" do
                  name <> " - " <> desc
                else
                  name
                end
              )

    calculate :type_label,
              :string,
              expr(
                cond do
                  type == :location -> "Location"
                  type == :department -> "Department"
                  type == :environment -> "Environment"
                  type == :function -> "Function"
                  type == :custom -> "Custom"
                  true -> "Unknown"
                end
              )

    calculate :has_children, :boolean, expr(exists(children, true))

    calculate :is_empty, :boolean, expr(device_count == 0)
  end

  identities do
    identity :unique_name_per_tenant, [:tenant_id, :name]
  end
end
