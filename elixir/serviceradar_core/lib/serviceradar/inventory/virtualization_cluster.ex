defmodule ServiceRadar.Inventory.VirtualizationCluster do
  @moduledoc """
  Provider-neutral virtualization cluster inventory.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @devices_view_check {ActorHasPermission, permission: "devices.view"}
  @devices_update_check {ActorHasPermission, permission: "devices.update"}
  @devices_delete_check {ActorHasPermission, permission: "devices.delete"}
  @identity_fields [
    :provider,
    :provider_ref,
    :identity_version,
    :identity_state,
    :integration_id,
    :controller_id,
    :native_cluster_id,
    :object_kind,
    :native_object_id,
    :provider_instance_ref
  ]
  @mutable_fields [:name, :status, :version, :metadata, :observed_at]

  postgres do
    table "virtualization_clusters"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @identity_fields ++ @mutable_fields
    end

    update :update do
      accept @mutable_fields
    end

    read :by_provider_ref do
      argument :provider, :string, allow_nil?: false
      argument :provider_ref, :string, allow_nil?: false
      get? true
      filter expr(provider == ^arg(:provider) and provider_ref == ^arg(:provider_ref))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@devices_view_check)
    action_type_with_permission(:create, @devices_update_check)
    action_type_with_permission(:update, @devices_update_check)
    action_type_with_permission(:destroy, @devices_delete_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
    end

    attribute :provider_ref, :string do
      allow_nil? false
      public? true
    end

    attribute :identity_version, :integer do
      public? true
    end

    attribute :identity_state, :atom do
      allow_nil? false
      default :legacy
      public? true
      constraints one_of: [:legacy, :authoritative, :quarantined]
    end

    attribute :integration_id, :uuid do
      public? true
    end

    attribute :controller_id, :uuid do
      public? true
    end

    attribute :native_cluster_id, :string do
      public? true
    end

    attribute :object_kind, :string do
      public? true
    end

    attribute :native_object_id, :string do
      public? true
    end

    attribute :provider_instance_ref, :string do
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :string do
      public? true
    end

    attribute :version, :string do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :observed_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :hosts, ServiceRadar.Inventory.VirtualizationHost do
      destination_attribute :cluster_id
      public? true
    end

    has_many :datastores, ServiceRadar.Inventory.VirtualizationDatastore do
      destination_attribute :cluster_id
      public? true
    end

    has_many :storage_systems, ServiceRadar.Inventory.VirtualizationStorageSystem do
      destination_attribute :cluster_id
      public? true
    end
  end

  identities do
    identity :unique_provider_ref, [:provider, :provider_ref]
  end
end
