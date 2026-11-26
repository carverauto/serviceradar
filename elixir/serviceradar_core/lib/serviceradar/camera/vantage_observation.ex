defmodule ServiceRadar.Camera.VantageObservation do
  @moduledoc """
  Retention-coupled Vantage ML observation store (`platform.camera_vantage_observations`)
  populated exclusively from NATS JetStream (`media.results.vantage.v1`) via
  Core `EventWriter`.

  Recorded observations (`source_mode: :recorded_block`) link to `RecordingCatalogEntry`
  via `ON DELETE CASCADE` and are immediately purged on `quarantined` or terminal
  deletion by `trg_camera_recording_catalog_purge_vantage` while `RecordingHold`
  preserves held blocks. Live-tap observations (`source_mode: :live_keyframe_tap`)
  expire via pipeline-configured `live_observation_retention_days`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Changeset.OriginalDataNotAvailable
  alias Ash.Error.Changes.InvalidAttribute
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.Validations.VantageCropJpeg
  alias ServiceRadar.Camera.VantageJob
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @source_modes [:recorded_block, :live_keyframe_tap]
  @time_bases [:received, :camera_reported]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}

  defmodule ValidateVantageObservation do
    @moduledoc false
    use Ash.Resource.Validation

    @impl true
    def validate(changeset, _opts, _context) do
      source_mode = proposed_value(changeset, :source_mode)
      catalog_entry_id = proposed_value(changeset, :catalog_entry_id)
      bbox = proposed_value(changeset, :bbox)
      confidence = proposed_value(changeset, :confidence)

      with :ok <- validate_recorded_catalog_link(source_mode, catalog_entry_id),
           :ok <- validate_confidence(confidence) do
        validate_bbox(bbox)
      end
    end

    @impl true
    def atomic(changeset, opts, context) do
      validate(changeset, opts, context)
    end

    defp validate_recorded_catalog_link(:recorded_block, nil) do
      {:error,
       InvalidAttribute.exception(
         field: :catalog_entry_id,
         message: "is required when source_mode is recorded_block"
       )}
    end

    defp validate_recorded_catalog_link(_source_mode, _catalog_entry_id), do: :ok

    defp validate_confidence(nil), do: :ok
    defp validate_confidence(conf) when is_number(conf) and conf >= 0.0 and conf <= 1.0, do: :ok

    defp validate_confidence(_) do
      {:error,
       InvalidAttribute.exception(field: :confidence, message: "must be between 0.0 and 1.0")}
    end

    defp validate_bbox(nil), do: :ok

    defp validate_bbox(bbox) when is_map(bbox) do
      x1 = Map.get(bbox, "x1") || Map.get(bbox, :x1)
      y1 = Map.get(bbox, "y1") || Map.get(bbox, :y1)
      x2 = Map.get(bbox, "x2") || Map.get(bbox, :x2)
      y2 = Map.get(bbox, "y2") || Map.get(bbox, :y2)

      if valid_unit_coord?(x1) and valid_unit_coord?(y1) and valid_unit_coord?(x2) and
           valid_unit_coord?(y2) and x1 < x2 and y1 < y2 do
        :ok
      else
        {:error,
         InvalidAttribute.exception(
           field: :bbox,
           message: "must contain normalized x1, y1, x2, y2 in 0.0..1.0 with x1 < x2 and y1 < y2"
         )}
      end
    end

    defp validate_bbox(_) do
      {:error, InvalidAttribute.exception(field: :bbox, message: "must be a map")}
    end

    defp valid_unit_coord?(v), do: is_number(v) and v >= 0.0 and v <= 1.0

    defp proposed_value(changeset, field) do
      case Ash.Changeset.fetch_change(changeset, field) do
        {:ok, value} -> value
        :error -> existing_value(changeset, field)
      end
    end

    defp existing_value(changeset, field) do
      case Ash.Changeset.get_data(changeset, field) do
        %OriginalDataNotAvailable{} -> nil
        value -> value
      end
    rescue
      _ -> nil
    end
  end

  postgres do
    table "camera_vantage_observations"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names unique_observation_key: "camera_vantage_observations_key_uidx"

    custom_indexes do
      index [:camera_source_id, :timeline_ts_us],
        name: "camera_vantage_observations_camera_timeline_idx"

      index [:catalog_entry_id, :timeline_ts_us],
        name: "camera_vantage_observations_catalog_timeline_idx",
        where: "catalog_entry_id IS NOT NULL"

      index [:signal_schema_id, :category, :timeline_ts_us],
        name: "camera_vantage_observations_schema_cat_timeline_idx"

      index [:source_mode, :inserted_at],
        name: "camera_vantage_observations_live_retention_idx",
        where: "source_mode = 'live_keyframe_tap'"
    end

    references do
      reference :catalog_entry,
        on_delete: :delete,
        name: "camera_vantage_observations_catalog_entry_fkey"

      reference :camera_source,
        on_delete: :delete,
        name: "camera_vantage_observations_camera_source_fkey"

      reference :vantage_job,
        on_delete: :nilify,
        name: "camera_vantage_observations_job_fkey"
    end

    check_constraints do
      check_constraint :observation_key, "camera_vantage_observations_valid",
        check: """
        source_mode IN ('recorded_block', 'live_keyframe_tap') AND
        (source_mode <> 'recorded_block' OR catalog_entry_id IS NOT NULL) AND
        time_basis IN ('received', 'camera_reported') AND
        (fragment_sequence IS NULL OR fragment_sequence >= 0) AND
        (frame_sequence IS NULL OR frame_sequence >= 0) AND
        (media_pts_ns IS NULL OR media_pts_ns >= 0) AND
        confidence >= 0.0 AND confidence <= 1.0 AND
        btrim(observation_key) <> '' AND
        btrim(pipeline_id) <> '' AND
        btrim(pipeline_version) <> '' AND
        btrim(worker_kind) <> '' AND
        btrim(model_id) <> '' AND
        btrim(model_version) <> '' AND
        btrim(category) <> '' AND
        btrim(label) <> '' AND
        btrim(signal_schema_id) <> '' AND
        btrim(signal_schema_version) <> '' AND
        btrim(display_contract_id) <> ''
        """

      check_constraint :crop_jpeg, "camera_vantage_observations_crop_jpeg_size",
        check: "crop_jpeg IS NULL OR octet_length(crop_jpeg) <= 32768"
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_catalog_entry, action: :by_catalog_entry, args: [:catalog_entry_id]
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_catalog_entry do
      argument :catalog_entry_id, :uuid, allow_nil?: false
      filter expr(catalog_entry_id == ^arg(:catalog_entry_id))
    end

    create :upsert_observation do
      primary? true

      accept [
        :observation_key,
        :pack_id,
        :pipeline_id,
        :pipeline_version,
        :worker_kind,
        :worker_id,
        :model_id,
        :model_version,
        :job_id,
        :catalog_entry_id,
        :camera_source_id,
        :stream_profile_id,
        :source_mode,
        :fragment_sequence,
        :frame_sequence,
        :media_pts_ns,
        :timeline_ts_us,
        :time_basis,
        :track_id,
        :category,
        :label,
        :confidence,
        :bbox,
        :crop_jpeg,
        :attributes,
        :signal_schema_id,
        :signal_schema_version,
        :display_contract_id,
        :search_text
      ]

      upsert? true
      upsert_identity :unique_observation_key

      upsert_fields [
        :worker_kind,
        :worker_id,
        :model_id,
        :model_version,
        :label,
        :confidence,
        :bbox,
        :crop_jpeg,
        :attributes,
        :search_text,
        :updated_at
      ]

      validate {VantageCropJpeg, []}
      validate {ValidateVantageObservation, []}

      validate present([
                 :observation_key,
                 :pipeline_id,
                 :pipeline_version,
                 :worker_kind,
                 :model_id,
                 :model_version,
                 :camera_source_id,
                 :stream_profile_id,
                 :source_mode,
                 :timeline_ts_us,
                 :time_basis,
                 :category,
                 :label,
                 :confidence,
                 :signal_schema_id,
                 :signal_schema_version,
                 :display_contract_id
               ])
    end

    destroy :purge_expired_live do
      argument :pipeline_id, :string, allow_nil?: false
      argument :cutoff, :utc_datetime_usec, allow_nil?: false

      filter expr(
               source_mode == :live_keyframe_tap and
                 pipeline_id == ^arg(:pipeline_id) and
                 inserted_at < ^arg(:cutoff)
             )
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

    policy action_type([:create, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :observation_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 512
    end

    attribute :pack_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
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

    attribute :worker_kind, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :worker_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :model_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :model_version, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :job_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :catalog_entry_id, :uuid do
      allow_nil? true
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

    attribute :source_mode, :atom do
      allow_nil? false
      default :recorded_block
      public? true
      constraints one_of: @source_modes
    end

    attribute :fragment_sequence, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :frame_sequence, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :media_pts_ns, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :timeline_ts_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :time_basis, :atom do
      allow_nil? false
      default :received
      public? true
      constraints one_of: @time_bases
    end

    attribute :track_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :category, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :label, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 512
    end

    attribute :confidence, :float do
      allow_nil? false
      public? true
      constraints min: 0.0, max: 1.0
    end

    attribute :bbox, :map do
      allow_nil? true
      public? true
    end

    attribute :crop_jpeg, :binary do
      allow_nil? true
      public? false
      sensitive? true
      select_by_default? false
    end

    attribute :attributes, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :signal_schema_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :signal_schema_version, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :display_contract_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :search_text, :string do
      allow_nil? false
      default ""
      public? true
      constraints allow_empty?: true, trim?: false, max_length: 4096
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :catalog_entry, RecordingCatalogEntry do
      allow_nil? true
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

    belongs_to :vantage_job, VantageJob do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :job_id
    end
  end

  calculations do
    calculate :has_crop, :boolean, expr(not is_nil(crop_jpeg))
  end

  identities do
    identity :unique_observation_key, [:observation_key]
  end

  @doc "Allowed `source_mode` values (`:recorded_block | :live_keyframe_tap`)."
  @spec source_modes() :: [atom()]
  def source_modes, do: @source_modes

  @doc "Allowed `time_basis` values (`:received | :camera_reported`)."
  @spec time_bases() :: [atom()]
  def time_bases, do: @time_bases
end
