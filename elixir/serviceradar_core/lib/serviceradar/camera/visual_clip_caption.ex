defmodule ServiceRadar.Camera.VisualClipCaption do
  @moduledoc """
  Retention-coupled VLM action caption projection (`platform.camera_visual_clip_captions`)
  for recorded Smart event clips.

  Strictly coupled to `platform.camera_recording_catalog` via `ON DELETE CASCADE` and
  `trg_camera_recording_catalog_purge_visual_clip_captions` so transitions to
  `quarantined` or terminal copy deletion purge captions immediately while preserving
  captions for `RecordingHold`-pinned playable entries.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.VisualFrame
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @time_bases [:received, :camera_reported]
  @embedding_dims [512, 768, 1152]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}

  postgres do
    table "camera_visual_clip_captions"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names entry_span_model: "camera_visual_clip_captions_entry_span_model_index"

    custom_indexes do
      index [:camera_source_id, :start_us, :end_us],
        name: "camera_visual_clip_captions_camera_span_index"

      index [:catalog_entry_id],
        name: "camera_visual_clip_captions_catalog_entry_index"
    end

    references do
      reference :camera_source,
        on_delete: :delete,
        name: "camera_visual_clip_captions_camera_source_fkey"

      reference :catalog_entry,
        on_delete: :delete,
        name: "camera_visual_clip_captions_catalog_entry_fkey"

      reference :visual_frame,
        on_delete: :nilify,
        name: "camera_visual_clip_captions_visual_frame_fkey"
    end

    check_constraints do
      check_constraint :caption_text, "camera_visual_clip_captions_valid",
        check: """
        end_us >= start_us AND
        time_basis IN ('received', 'camera_reported') AND
        btrim(caption_text) <> '' AND octet_length(caption_text) <= 4096 AND
        btrim(vlm_model_id) <> '' AND
        btrim(prompt_version) <> '' AND
        (caption_embedding IS NULL OR (embedding_dim IN (512, 768, 1152) AND vector_dims(caption_embedding) = embedding_dim))
        """
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_catalog_entry, action: :by_catalog_entry, args: [:catalog_entry_id]
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_catalog_entry do
      argument :catalog_entry_id, :uuid, allow_nil?: false
      filter expr(catalog_entry_id == ^arg(:catalog_entry_id))
    end

    create :upsert_caption do
      primary? true

      accept [
        :camera_source_id,
        :stream_profile_id,
        :catalog_entry_id,
        :visual_frame_id,
        :start_us,
        :end_us,
        :time_basis,
        :caption_text,
        :action_tags,
        :caption_embedding,
        :embedding_dim,
        :vlm_model_id,
        :prompt_version,
        :embedder_model_id,
        :embedder_model_version,
        :generated_at
      ]

      upsert? true
      upsert_identity :entry_span_model

      upsert_fields [
        :visual_frame_id,
        :time_basis,
        :caption_text,
        :action_tags,
        :caption_embedding,
        :embedding_dim,
        :embedder_model_id,
        :embedder_model_version,
        :generated_at,
        :updated_at
      ]

      validate present([
                 :camera_source_id,
                 :stream_profile_id,
                 :catalog_entry_id,
                 :start_us,
                 :end_us,
                 :time_basis,
                 :caption_text,
                 :vlm_model_id,
                 :prompt_version
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

    attribute :camera_source_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :stream_profile_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :catalog_entry_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :visual_frame_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :start_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :end_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :time_basis, :atom do
      allow_nil? false
      default :received
      public? true
      constraints one_of: @time_bases
    end

    attribute :caption_text, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 4096
    end

    attribute :action_tags, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :caption_embedding, Ash.Type.Vector do
      allow_nil? true
      public? true
    end

    attribute :embedding_dim, :integer do
      allow_nil? true
      public? true
      constraints min: 512, max: 1152
    end

    attribute :vlm_model_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :prompt_version, :string do
      allow_nil? false
      default "v1"
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :embedder_model_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :embedder_model_version, :string do
      allow_nil? true
      public? true
      constraints max_length: 64
    end

    attribute :generated_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :camera_source, Source do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :camera_source_id
    end

    belongs_to :catalog_entry, RecordingCatalogEntry do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :catalog_entry_id
    end

    belongs_to :visual_frame, VisualFrame do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :visual_frame_id
    end
  end

  identities do
    identity :entry_span_model, [
      :catalog_entry_id,
      :start_us,
      :end_us,
      :vlm_model_id,
      :prompt_version
    ]
  end

  @doc "Allowed `time_basis` values (`:received | :camera_reported`)."
  @spec time_bases() :: [atom()]
  def time_bases, do: @time_bases

  @doc "Supported caption embedding vector dimensions (`[512, 768, 1152]`)."
  @spec embedding_dims() :: [pos_integer()]
  def embedding_dims, do: @embedding_dims
end
