defmodule ServiceRadar.Inventory.EndpointPackage do
  @moduledoc """
  Normalized endpoint-side software package coordinate.

  Device membership stays in `EndpointInventoryPackage` current-state rows so
  package membership is a CNPG relation, not an AGE topology edge.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "endpoint_packages"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_coordinate_key, action: :by_coordinate_key, args: [:coordinate_key]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :coordinate_key,
        :purl_canonical,
        :primary_cpe,
        :cpes,
        :package_manager,
        :name,
        :version,
        :architecture,
        :ecosystem,
        :source_scope,
        :metadata
      ]
    end

    read :by_coordinate_key do
      argument :coordinate_key, :string, allow_nil?: false
      get? true
      filter expr(coordinate_key == ^arg(:coordinate_key))
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

    attribute :coordinate_key, :string do
      allow_nil? false
      public? true
    end

    attribute :purl_canonical, :string do
      public? true
    end

    attribute :primary_cpe, :string do
      public? true
    end

    attribute :cpes, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :package_manager, :string do
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

    attribute :ecosystem, :string do
      public? true
    end

    attribute :source_scope, :string do
      allow_nil? false
      default "host"
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
    has_many :device_package_rows, ServiceRadar.Inventory.EndpointInventoryPackage do
      source_attribute :id
      destination_attribute :endpoint_package_ref
      public? true
    end
  end

  identities do
    identity :unique_coordinate_key, [:coordinate_key]
  end
end
