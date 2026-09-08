defmodule ServiceRadar.Inventory.EndpointInventoryPackage do
  @moduledoc """
  Normalized package/component row from an endpoint inventory SBOM.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "endpoint_inventory_packages"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_current_by_agent, action: :current_by_agent, args: [:agent_id]
    define :list_current_by_device, action: :current_by_device, args: [:device_uid]
    define :count_current_by_device, action: :count_current_by_device, args: [:device_uid]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :scan_ref,
        :device_uid,
        :agent_id,
        :name,
        :version,
        :architecture,
        :package_manager,
        :ecosystem,
        :purl,
        :purl_canonical,
        :endpoint_package_ref,
        :cpes,
        :supplier,
        :license,
        :source,
        :evidence,
        :current,
        :metadata
      ]
    end

    read :current_by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id) and current == true)
      prepare build(sort: [package_manager: :asc, name: :asc, version: :asc])
    end

    read :current_by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid) and current == true)
      prepare build(sort: [package_manager: :asc, name: :asc, version: :asc])
    end

    # Paginated + filterable view of current packages for a device. Drives the
    # device "Software" tab so every package row is reachable (not capped at a
    # fixed limit) and filterable server-side. All text filters are optional and
    # case-insensitive substring matches; blank/nil args are ignored.
    read :current_by_device_paged do
      argument :device_uid, :string, allow_nil?: false
      argument :q, :string, allow_nil?: true
      argument :package_manager, :string, allow_nil?: true
      argument :version, :string, allow_nil?: true
      argument :purl, :string, allow_nil?: true
      argument :cpe, :string, allow_nil?: true

      filter expr(device_uid == ^arg(:device_uid) and current == true)

      filter expr(
               is_nil(^arg(:q)) or
                 contains(name, ^arg(:q)) or contains(version, ^arg(:q)) or
                 contains(package_manager, ^arg(:q)) or contains(architecture, ^arg(:q)) or
                 contains(purl, ^arg(:q)) or contains(purl_canonical, ^arg(:q))
             )

      filter expr(
               is_nil(^arg(:package_manager)) or contains(package_manager, ^arg(:package_manager))
             )

      filter expr(is_nil(^arg(:version)) or contains(version, ^arg(:version)))

      filter expr(
               is_nil(^arg(:purl)) or contains(purl, ^arg(:purl)) or
                 contains(purl_canonical, ^arg(:purl))
             )

      filter expr(
               is_nil(^arg(:cpe)) or
                 contains(fragment("array_to_string(?, ' ')", cpes), ^arg(:cpe))
             )

      pagination offset?: true, default_limit: 100, max_page_size: 500, countable: true
      prepare build(sort: [package_manager: :asc, name: :asc, version: :asc])
    end

    # Count of stored current package rows for a device. Used to make the
    # "reported N vs stored M" warning reflect the real total instead of the
    # capped page size.
    read :count_current_by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid) and current == true)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type(:create)
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :scan_ref, :uuid do
      allow_nil? false
      public? true
    end

    attribute :device_uid, :string do
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :version, :string do
      public? true
    end

    attribute :architecture, :string do
      public? true
    end

    attribute :package_manager, :string do
      allow_nil? false
      public? true
    end

    attribute :ecosystem, :string do
      public? true
    end

    attribute :purl, :string do
      public? true
    end

    attribute :purl_canonical, :string do
      allow_nil? false
      public? true
    end

    attribute :endpoint_package_ref, :uuid do
      allow_nil? false
      public? true
    end

    attribute :cpes, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :supplier, :string do
      public? true
    end

    attribute :license, :string do
      public? true
    end

    attribute :source, :string do
      public? true
    end

    attribute :evidence, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :current, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :scan, ServiceRadar.Inventory.EndpointInventoryScan do
      source_attribute :scan_ref
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end

    belongs_to :package, ServiceRadar.Inventory.EndpointPackage do
      source_attribute :endpoint_package_ref
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end
  end
end
