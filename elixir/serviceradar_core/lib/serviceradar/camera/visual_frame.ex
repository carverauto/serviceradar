defmodule ServiceRadar.Camera.VisualFrame do
  @moduledoc """
  Retention-coupled CNPG projection (`platform.camera_visual_frames`) of a
  sampled IDR keyframe from a sealed, non-quarantined `RecordingCatalogEntry`
  (`1.2`, `1.3`, `3.1`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.VisualEmbedding
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @time_bases [:received, :camera_reported]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}

  postgres do
    table "camera_visual_frames"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names entry_fragment_detector:
                           "camera_visual_frames_entry_fragment_detector_index"

    custom_indexes do
      index [:camera_source_id, :timeline_ts_us, :catalog_entry_id],
        name: "camera_visual_frames_camera_timeline_index"
    end

    references do
      reference :catalog_entry,
        on_delete: :delete,
        name: "camera_visual_frames_catalog_entry_fkey"

      reference :camera_source,
        on_delete: :delete,
        name: "camera_visual_frames_camera_source_fkey"
    end

    check_constraints do
      check_constraint :fragment_sequence, "camera_visual_frames_valid",
        check: """
        fragment_sequence >= 0 AND
        media_pts_ns >= 0 AND
        time_basis IN ('received', 'camera_reported') AND
        btrim(detector_model_id) <> '' AND
        btrim(detector_model_version) <> ''
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

    create :upsert_frame do
      primary? true

      accept [
        :catalog_entry_id,
        :camera_source_id,
        :stream_profile_id,
        :fragment_sequence,
        :media_pts_ns,
        :timeline_ts_us,
        :time_basis,
        :scene_suppressed,
        :detector_model_id,
        :detector_model_version,
        :detections
      ]

      upsert? true
      upsert_identity :entry_fragment_detector

      upsert_fields [
        :media_pts_ns,
        :timeline_ts_us,
        :time_basis,
        :scene_suppressed,
        :detections,
        :updated_at
      ]

      validate present([
                 :catalog_entry_id,
                 :camera_source_id,
                 :stream_profile_id,
                 :fragment_sequence,
                 :media_pts_ns,
                 :timeline_ts_us,
                 :time_basis,
                 :detector_model_id,
                 :detector_model_version
               ])
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

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :system)
    end
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

    attribute :fragment_sequence, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :media_pts_ns, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :timeline_ts_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :time_basis, :atom do
      allow_nil? false
      public? true
      constraints one_of: @time_bases
    end

    attribute :scene_suppressed, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :detector_model_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :detector_model_version, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :detections, {:array, :map} do
      allow_nil? false
      default []
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

    has_many :embeddings, VisualEmbedding do
      public? true
      destination_attribute :visual_frame_id
    end
  end

  identities do
    identity :entry_fragment_detector, [
      :catalog_entry_id,
      :fragment_sequence,
      :detector_model_id,
      :detector_model_version
    ]
  end

  @doc "Allowed `time_basis` values (`:received | :camera_reported`)."
  @spec time_bases() :: [atom()]
  def time_bases, do: @time_bases
end
