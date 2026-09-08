defmodule ServiceRadar.Camera.Source do
  @moduledoc """
  Normalized camera source inventory linked to a canonical device.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @devices_view_check {ActorHasPermission, permission: "devices.view"}

  @mutable_fields [
    :device_uid,
    :display_name,
    :source_url,
    :assigned_agent_id,
    :assigned_gateway_id,
    :availability_status,
    :availability_reason,
    :last_activity_at,
    :last_event_at,
    :last_event_type,
    :last_event_message,
    :metadata
  ]

  postgres do
    table "camera_sources"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_device, action: :for_device, args: [:device_uid]
    define :create_source, action: :create
    define :update_source, action: :update
    define :upsert_source, action: :upsert
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [inserted_at: :asc])
    end

    create :create do
      accept [
        :device_uid,
        :vendor,
        :vendor_camera_id,
        :display_name,
        :source_url,
        :assigned_agent_id,
        :assigned_gateway_id,
        :availability_status,
        :availability_reason,
        :last_activity_at,
        :last_event_at,
        :last_event_type,
        :last_event_message,
        :metadata
      ]
    end

    update :update do
      accept @mutable_fields
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_vendor_camera

      accept [
        :device_uid,
        :vendor,
        :vendor_camera_id,
        :display_name,
        :source_url,
        :assigned_agent_id,
        :assigned_gateway_id,
        :availability_status,
        :availability_reason,
        :last_activity_at,
        :last_event_at,
        :last_event_type,
        :last_event_message,
        :metadata
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@devices_view_check)

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :vendor, :string do
      allow_nil? false
      public? true
    end

    attribute :vendor_camera_id, :string do
      allow_nil? false
      public? true
    end

    attribute :display_name, :string do
      public? true
    end

    attribute :source_url, :string do
      public? true
    end

    attribute :assigned_agent_id, :string do
      public? true
    end

    attribute :assigned_gateway_id, :string do
      public? true
    end

    attribute :availability_status, :string do
      public? true
    end

    attribute :availability_reason, :string do
      public? true
    end

    attribute :last_activity_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_event_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_event_type, :string do
      public? true
    end

    attribute :last_event_message, :string do
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
    has_many :stream_profiles, ServiceRadar.Camera.StreamProfile do
      destination_attribute :camera_source_id
      public? true
    end
  end

  identities do
    identity :unique_vendor_camera, [:vendor, :vendor_camera_id]
  end
end
