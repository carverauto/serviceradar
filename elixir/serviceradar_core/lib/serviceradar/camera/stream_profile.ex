defmodule ServiceRadar.Camera.StreamProfile do
  @moduledoc """
  Relay-capable stream profile for a normalized camera source.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @devices_view_check {ActorHasPermission, permission: "devices.view"}

  @mutable_fields [
    :profile_name,
    :vendor_profile_id,
    :source_origin,
    :rtsp_transport,
    :codec_hint,
    :container_hint,
    :relay_eligible,
    :last_seen_at,
    :metadata
  ]

  postgres do
    table "camera_stream_profiles"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_for_relay, action: :for_relay, args: [:id, :camera_source_id]
    define :create_profile, action: :create
    define :update_profile, action: :update
    define :upsert_profile, action: :upsert
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_relay do
      argument :id, :uuid, allow_nil?: false
      argument :camera_source_id, :uuid, allow_nil?: false

      get? true

      filter expr(
               id == ^arg(:id) and
                 camera_source_id == ^arg(:camera_source_id) and
                 relay_eligible == true
             )
    end

    create :create do
      accept [:camera_source_id | @mutable_fields]
    end

    update :update do
      accept @mutable_fields
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_profile_name_per_source

      accept [:camera_source_id | @mutable_fields]
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

    attribute :camera_source_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :profile_name, :string do
      allow_nil? false
      public? true
    end

    attribute :vendor_profile_id, :string do
      public? true
    end

    # The stream's origin (`scheme://host[:port]`), never a path, alias or userinfo:
    # inventory ingest writes it only through `StreamAddressReduction.origin/1`. The
    # address itself is resolved by the agent when a relay opens (design D1 of
    # resolve-camera-stream-sources-at-edge).
    attribute :source_origin, :string do
      public? true
    end

    attribute :rtsp_transport, :string do
      public? true
    end

    attribute :codec_hint, :string do
      public? true
    end

    attribute :container_hint, :string do
      public? true
    end

    attribute :relay_eligible, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :last_seen_at, :utc_datetime_usec do
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
    belongs_to :camera_source, ServiceRadar.Camera.Source do
      allow_nil? false
      public? true
      source_attribute :camera_source_id
      destination_attribute :id
      define_attribute? false
    end
  end

  calculations do
    # The scheme of the profile's stream (`rtsp`, `rtsps`, ...), lowercased, or nil
    # when inventory holds no origin, so a reader learns whether the stream is TLS.
    calculate :source_scheme,
              :string,
              expr(
                fragment(
                  "lower(substring(nullif(btrim(?), '') from '^([A-Za-z][A-Za-z0-9+.-]*)://'))",
                  source_origin
                )
              ) do
      public? true
    end
  end

  identities do
    identity :unique_profile_name_per_source, [:camera_source_id, :profile_name]
  end
end
