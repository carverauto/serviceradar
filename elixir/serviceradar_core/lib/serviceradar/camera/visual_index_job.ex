defmodule ServiceRadar.Camera.VisualIndexJob do
  @moduledoc """
  Durable CNPG outbox and lifecycle record (`platform.camera_visual_index_jobs`)
  for recorded-block visual keyframe indexing (`1.2`–`1.4`).

  Jobs are admitted only for sealed, non-quarantined `RecordingCatalogEntry`
  blocks whose `CameraRecordingPolicy` enables `visual_index_mode == :keyframes`
  (or via bounded model-upgrade backfill) and are published as metadata-only
  envelopes to NATS JetStream (`media.jobs.visual_index.v1` and
  `media.jobs.visual_index.backfill.v1`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @hex64 ~r/\A[0-9a-f]{64}\z/
  @error_class_pattern ~r/\A[a-z0-9_:-]+\z/
  @job_kinds [:live, :backfill]
  @states [:pending, :dispatched, :completed, :cancelled, :failed_terminal]
  @embedding_dims [512, 768]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}

  postgres do
    table "camera_visual_index_jobs"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names catalog_embedder: "camera_visual_index_jobs_catalog_embedder_index"

    custom_indexes do
      index [:state, :job_kind, :inserted_at],
        name: "camera_visual_index_jobs_active_queue_index",
        where: "state IN ('pending', 'dispatched')"

      index [:camera_source_id, :state],
        name: "camera_visual_index_jobs_camera_state_index"
    end

    references do
      reference :catalog_entry,
        on_delete: :delete,
        name: "camera_visual_index_jobs_catalog_entry_fkey"

      reference :camera_source,
        on_delete: :delete,
        name: "camera_visual_index_jobs_camera_source_fkey"
    end

    check_constraints do
      check_constraint :state, "camera_visual_index_jobs_valid",
        check: """
        job_kind IN ('live', 'backfill') AND
        state IN ('pending', 'dispatched', 'completed', 'cancelled', 'failed_terminal') AND
        attempt_count >= 0 AND
        max_attempts >= 1 AND
        embedding_dim IN (512, 768) AND
        btrim(detector_model_id) <> '' AND
        btrim(detector_model_version) <> '' AND
        btrim(embedder_model_id) <> '' AND
        btrim(embedder_model_version) <> '' AND
        descriptor_sha256 ~ '^[0-9a-f]{64}$' AND
        (last_error_class IS NULL OR (octet_length(last_error_class) BETWEEN 1 AND 64 AND last_error_class ~ '^[a-z0-9_:-]+$'))
        """
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    create :enqueue do
      primary? true

      accept [
        :catalog_entry_id,
        :camera_source_id,
        :stream_profile_id,
        :job_kind,
        :state,
        :attempt_count,
        :max_attempts,
        :detector_model_id,
        :detector_model_version,
        :embedder_model_id,
        :embedder_model_version,
        :embedding_dim,
        :sampled_fragments,
        :descriptor_sha256,
        :deadline_at
      ]

      upsert? true
      upsert_identity :catalog_embedder
      upsert_fields []

      validate present([
                 :catalog_entry_id,
                 :camera_source_id,
                 :stream_profile_id,
                 :detector_model_id,
                 :detector_model_version,
                 :embedder_model_id,
                 :embedder_model_version,
                 :embedding_dim,
                 :descriptor_sha256
               ])
    end

    update :mark_dispatched do
      accept [:dispatched_at, :deadline_at, :last_error_class]
      change set_attribute(:state, :dispatched)
      change atomic_update(:attempt_count, expr(attempt_count + 1))
      validate present([:dispatched_at, :deadline_at])
    end

    update :mark_completed do
      accept [:completed_at]
      change set_attribute(:state, :completed)
      change set_attribute(:last_error_class, nil)
      validate present([:completed_at])
    end

    update :mark_cancelled do
      accept [:last_error_class]
      change set_attribute(:state, :cancelled)
    end

    update :mark_failed_terminal do
      accept [:last_error_class]
      change set_attribute(:state, :failed_terminal)
      validate present([:last_error_class])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @operate_check
      authorize_if @footage_view_check
    end

    policy action_type([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  validations do
    validate one_of(:embedding_dim, @embedding_dims)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :catalog_entry_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :camera_source_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :stream_profile_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :job_kind, :atom do
      allow_nil? false
      default :live
      public? true
      constraints one_of: @job_kinds
    end

    attribute :state, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: @states
    end

    attribute :attempt_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :max_attempts, :integer do
      allow_nil? false
      default 5
      public? true
      constraints min: 1
    end

    attribute :detector_model_id, :string do
      allow_nil? false
      default "rtdetr-r18"
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :detector_model_version, :string do
      allow_nil? false
      default "2026.1"
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :embedder_model_id, :string do
      allow_nil? false
      default "siglip-b16-384"
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :embedder_model_version, :string do
      allow_nil? false
      default "2026.1"
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :embedding_dim, :integer do
      allow_nil? false
      default 768
      public? true
      constraints min: 512, max: 768
    end

    attribute :sampled_fragments, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :descriptor_sha256, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64, match: @hex64
    end

    attribute :last_error_class, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 64, match: @error_class_pattern
    end

    attribute :dispatched_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :deadline_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :catalog_entry, RecordingCatalogEntry do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :catalog_entry_id
    end

    belongs_to :camera_source, Source do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :camera_source_id
    end
  end

  identities do
    identity :catalog_embedder, [:catalog_entry_id, :embedder_model_id, :embedder_model_version]
  end

  @doc "Allowed `job_kind` values (`:live | :backfill`)."
  @spec job_kinds() :: [atom()]
  def job_kinds, do: @job_kinds

  @doc "Allowed `VisualIndexJob` states."
  @spec states() :: [atom()]
  def states, do: @states

  @doc "Supported embedding vector dimensions (`[512, 768]`)."
  @spec embedding_dims() :: [pos_integer()]
  def embedding_dims, do: @embedding_dims
end
