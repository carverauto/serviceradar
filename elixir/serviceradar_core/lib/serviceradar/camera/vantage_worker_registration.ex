defmodule ServiceRadar.Camera.VantageWorkerRegistration do
  @moduledoc """
  Ephemeral capability and health registry (`platform.vantage_worker_registrations`)
  for `vantage.worker.v1` and `camera_vlm` workers, populated from
  `media.workers.heartbeat.v1` heartbeats with bounded `expires_at` TTLs.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @worker_kinds [:camera_vlm, :external_rust, :external_python]
  @health_states [:ready, :degraded, :draining, :unhealthy]
  @execution_backends ["onnx", "candle", "vlm", "custom"]
  @architectures ["arm64", "amd64"]

  @mutable_fields [
    :worker_kind,
    :protocol_version,
    :capabilities,
    :supported_source_modes,
    :execution_backend,
    :architecture,
    :model_id,
    :model_version,
    :max_concurrency,
    :active_jobs,
    :health,
    :metadata,
    :last_heartbeat_at,
    :expires_at
  ]

  @all_fields [:worker_id | @mutable_fields]

  @catalog_view_check {ActorHasPermission, permission: "catalog.view"}
  @recording_view_check {ActorHasPermission, permission: "settings.recording.view"}
  @recording_manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @devices_view_check {ActorHasPermission, permission: "devices.view"}

  postgres do
    table "vantage_worker_registrations"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names unique_worker_id: "vantage_worker_registrations_worker_id_uidx"

    custom_indexes do
      index [:expires_at], name: "vantage_worker_registrations_expires_at_idx"
    end

    check_constraints do
      check_constraint :worker_id, "vantage_worker_registrations_valid",
        check: """
        btrim(worker_id) <> '' AND
        worker_kind IN ('camera_vlm', 'external_rust', 'external_python') AND
        btrim(protocol_version) <> '' AND
        execution_backend IN ('onnx', 'candle', 'vlm', 'custom') AND
        architecture IN ('arm64', 'amd64') AND
        max_concurrency >= 1 AND
        active_jobs >= 0 AND
        health IN ('ready', 'degraded', 'draining', 'unhealthy')
        """
    end
  end

  code_interface do
    define :active_for_capability, action: :active_for_capability, args: [:capability, :now]

    define :eligible_for_dispatch,
      action: :eligible_for_dispatch,
      args: [:capability, :source_mode, :now]
  end

  actions do
    defaults [:read, :destroy]

    read :active_for_capability do
      argument :capability, :string, allow_nil?: false
      argument :now, :utc_datetime_usec, allow_nil?: false

      filter expr(
               expires_at > ^arg(:now) and
                 health == :ready and
                 active_jobs < max_concurrency and
                 ^arg(:capability) in capabilities
             )
    end

    read :eligible_for_dispatch do
      argument :capability, :string, allow_nil?: false
      argument :source_mode, :string, allow_nil?: false
      argument :now, :utc_datetime_usec, allow_nil?: false

      filter expr(
               expires_at > ^arg(:now) and
                 health == :ready and
                 active_jobs < max_concurrency and
                 ^arg(:capability) in capabilities and
                 ^arg(:source_mode) in supported_source_modes
             )
    end

    create :upsert_heartbeat do
      primary? true
      accept @all_fields
      upsert? true
      upsert_identity :unique_worker_id
      upsert_fields @mutable_fields ++ [:updated_at]

      validate present([
                 :worker_id,
                 :worker_kind,
                 :protocol_version,
                 :execution_backend,
                 :architecture,
                 :last_heartbeat_at,
                 :expires_at
               ])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @catalog_view_check
      authorize_if @recording_view_check
      authorize_if @recording_manage_check
      authorize_if @devices_view_check
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :worker_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :worker_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @worker_kinds
    end

    attribute :protocol_version, :string do
      allow_nil? false
      default "vantage.worker.v1"
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :capabilities, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :supported_source_modes, {:array, :string} do
      allow_nil? false
      default ["recorded_block"]
      public? true
    end

    attribute :execution_backend, :string do
      allow_nil? false
      default "custom"
      public? true
      constraints min_length: 1, max_length: 32
    end

    attribute :architecture, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 16
    end

    attribute :model_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :model_version, :string do
      allow_nil? true
      public? true
      constraints max_length: 64
    end

    attribute :max_concurrency, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1
    end

    attribute :active_jobs, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :health, :atom do
      allow_nil? false
      default :ready
      public? true
      constraints one_of: @health_states
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :last_heartbeat_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  identities do
    identity :unique_worker_id, [:worker_id]
  end

  @doc "Allowed `worker_kind` values."
  @spec worker_kinds() :: [atom()]
  def worker_kinds, do: @worker_kinds

  @doc "Allowed `health` values."
  @spec health_states() :: [atom()]
  def health_states, do: @health_states

  @doc "Allowed `execution_backend` strings."
  @spec execution_backends() :: [String.t()]
  def execution_backends, do: @execution_backends

  @doc "Allowed `architecture` strings."
  @spec architectures() :: [String.t()]
  def architectures, do: @architectures
end
