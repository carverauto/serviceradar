defmodule ServiceRadar.Camera.VantageJob do
  @moduledoc """
  Durable CNPG outbox and lifecycle record (`platform.camera_vantage_jobs`)
  for Vantage ML pipeline jobs admitted from Stage 1 detections, sealed blocks,
  or bounded backfill.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @hex64 ~r/\A[0-9a-f]{64}\z/
  @error_class_pattern ~r/\A[a-z0-9_:-]+\z/
  @job_kinds [:live, :backfill]
  @states [:pending, :dispatched, :completed, :cancelled, :failed_terminal]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}

  postgres do
    table "camera_vantage_jobs"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names unique_job_key: "camera_vantage_jobs_idempotency_uidx"

    custom_indexes do
      index [:state, :job_kind, :inserted_at],
        name: "camera_vantage_jobs_active_queue_idx",
        where: "state IN ('pending', 'dispatched')"

      index [:camera_source_id, :state],
        name: "camera_vantage_jobs_camera_state_idx"

      index [:pipeline_id, :inserted_at],
        name: "camera_vantage_jobs_pipeline_rate_idx"
    end

    references do
      reference :catalog_entry,
        on_delete: :delete,
        name: "camera_vantage_jobs_catalog_entry_fkey"

      reference :camera_source,
        on_delete: :delete,
        name: "camera_vantage_jobs_camera_source_fkey"

      reference :vantage_pipeline,
        on_delete: :nilify,
        name: "camera_vantage_jobs_pipeline_ref_fkey"
    end

    check_constraints do
      check_constraint :state, "camera_vantage_jobs_valid",
        check: """
        job_kind IN ('live', 'backfill') AND
        state IN ('pending', 'dispatched', 'completed', 'cancelled', 'failed_terminal') AND
        attempt_count >= 0 AND
        max_attempts >= 1 AND
        btrim(pipeline_id) <> '' AND
        btrim(pipeline_version) <> '' AND
        btrim(target_key) <> '' AND
        btrim(target_runner) <> '' AND
        btrim(subject) <> '' AND
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
        :vantage_pipeline_id,
        :pipeline_id,
        :pipeline_version,
        :catalog_entry_id,
        :camera_source_id,
        :stream_profile_id,
        :target_key,
        :job_kind,
        :state,
        :target_runner,
        :subject,
        :descriptor_sha256,
        :sampled_targets,
        :job_payload,
        :attempt_count,
        :max_attempts,
        :deadline_at
      ]

      upsert? true
      upsert_identity :unique_job_key
      upsert_fields []

      validate present([
                 :pipeline_id,
                 :pipeline_version,
                 :catalog_entry_id,
                 :camera_source_id,
                 :stream_profile_id,
                 :target_key,
                 :target_runner,
                 :subject,
                 :descriptor_sha256
               ])
    end

    update :mark_dispatched do
      accept [:dispatched_at, :deadline_at, :last_error_class, :target_runner, :subject]
      change set_attribute(:state, :dispatched)
      change atomic_update(:attempt_count, expr(attempt_count + 1))
      validate present([:dispatched_at, :deadline_at])
    end

    update :requeue_pending do
      accept [:last_error_class]
      change set_attribute(:state, :pending)
      change set_attribute(:deadline_at, nil)
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

  attributes do
    uuid_v7_primary_key :id

    attribute :vantage_pipeline_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :pipeline_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :pipeline_version, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 64
    end

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

    attribute :target_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
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

    attribute :target_runner, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :descriptor_sha256, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64, match: @hex64
    end

    attribute :sampled_targets, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :job_payload, :map do
      allow_nil? false
      default %{}
      public? true
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

    belongs_to :vantage_pipeline, VantagePipeline do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :vantage_pipeline_id
    end
  end

  identities do
    identity :unique_job_key, [:pipeline_id, :pipeline_version, :catalog_entry_id, :target_key]
  end

  @doc "Allowed `job_kind` values (`:live | :backfill`)."
  @spec job_kinds() :: [atom()]
  def job_kinds, do: @job_kinds

  @doc "Allowed `VantageJob` states."
  @spec states() :: [atom()]
  def states, do: @states
end
