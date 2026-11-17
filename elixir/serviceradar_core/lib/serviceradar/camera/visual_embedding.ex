defmodule ServiceRadar.Camera.VisualEmbedding do
  @moduledoc """
  Retention-coupled `pgvector` vision-language embedding projection
  (`platform.camera_visual_embeddings`) for `:scene` and foreground `:crop`
  regions extracted from `VisualFrame` keyframes (`1.2`, `1.3`, `3.1`, `3.2`).

  Strictly coupled to `platform.camera_recording_catalog` via both `ON DELETE CASCADE`
  and `trg_camera_recording_catalog_purge_visual_index` so transitions to
  `quarantined` or terminal copy deletion (`local_state = 'reclaimed'` and
  `archive_state IN ('deleted', 'not_required')`) purge visual frames and
  embeddings immediately even while 90-day catalog tombstones remain.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset.OriginalDataNotAvailable
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.VisualFrame
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @region_kinds [:scene, :crop]
  @embedding_dims [512, 768]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}

  defmodule ValidateVisualEmbedding do
    @moduledoc false
    use Ash.Resource.Validation

    alias Ash.Error.Changes.InvalidAttribute

    @impl true
    def validate(changeset, _opts, _context) do
      region_kind = proposed_value(changeset, :region_kind)
      bbox = proposed_value(changeset, :bbox)
      confidence = proposed_value(changeset, :confidence)
      embedding_dim = proposed_value(changeset, :embedding_dim)
      embedding = proposed_value(changeset, :embedding)

      with :ok <- validate_confidence(confidence),
           :ok <- validate_bbox(region_kind, bbox) do
        validate_embedding_dim(embedding_dim, embedding)
      end
    end

    @impl true
    def atomic(changeset, opts, context) do
      validate(changeset, opts, context)
    end

    defp validate_confidence(nil), do: :ok

    defp validate_confidence(conf) when is_number(conf) and conf >= 0.0 and conf <= 1.0, do: :ok

    defp validate_confidence(_) do
      {:error,
       InvalidAttribute.exception(field: :confidence, message: "must be between 0.0 and 1.0")}
    end

    defp validate_bbox(:scene, nil), do: :ok

    defp validate_bbox(:scene, _non_nil) do
      {:error,
       InvalidAttribute.exception(field: :bbox, message: "must be nil when region_kind is scene")}
    end

    defp validate_bbox(_kind, nil), do: :ok

    defp validate_bbox(_kind, bbox) when is_map(bbox) do
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

    defp validate_bbox(_kind, _other) do
      {:error, InvalidAttribute.exception(field: :bbox, message: "must be a map")}
    end

    defp valid_unit_coord?(v), do: is_number(v) and v >= 0.0 and v <= 1.0

    defp validate_embedding_dim(dim, %Ash.Vector{dimensions: actual_dim} = vec)
         when dim in [512, 768] do
      if actual_dim == dim do
        validate_l2_norm(Ash.Vector.to_list(vec))
      else
        {:error,
         InvalidAttribute.exception(
           field: :embedding,
           message: "vector dimension #{actual_dim} does not match embedding_dim #{dim}"
         )}
      end
    end

    defp validate_embedding_dim(dim, list) when dim in [512, 768] and is_list(list) do
      if length(list) == dim do
        validate_l2_norm(list)
      else
        {:error,
         InvalidAttribute.exception(
           field: :embedding,
           message: "vector dimension #{length(list)} does not match embedding_dim #{dim}"
         )}
      end
    end

    defp validate_embedding_dim(_dim, _other) do
      {:error,
       InvalidAttribute.exception(
         field: :embedding,
         message: "must be a 512-d or 768-d normalized vector"
       )}
    end

    defp validate_l2_norm(values) do
      sum_sq =
        Enum.reduce_while(values, 0.0, fn
          v, acc when is_number(v) -> {:cont, acc + v * v}
          _other, _acc -> {:halt, :invalid}
        end)

      case sum_sq do
        :invalid ->
          {:error,
           InvalidAttribute.exception(field: :embedding, message: "must contain numeric floats")}

        sq when is_float(sq) and sq > 0.0 ->
          norm = :math.sqrt(sq)

          if abs(norm - 1.0) <= 0.05 do
            :ok
          else
            {:error,
             InvalidAttribute.exception(field: :embedding, message: "must be L2-normalized")}
          end

        _ ->
          {:error,
           InvalidAttribute.exception(field: :embedding, message: "must have non-zero norm")}
      end
    end

    defp proposed_value(changeset, field) do
      case Keyword.fetch(changeset.atomics, field) do
        {:ok, value} ->
          value

        :error ->
          case Ash.Changeset.fetch_change(changeset, field) do
            {:ok, value} -> value
            :error -> fallback_value(changeset, field)
          end
      end
    end

    defp fallback_value(changeset, field) do
      cond do
        Map.has_key?(changeset.attributes, field) ->
          Map.get(changeset.attributes, field)

        match?(%OriginalDataNotAvailable{}, changeset.data) ->
          nil

        is_map(changeset.data) ->
          Map.get(changeset.data, field)

        true ->
          nil
      end
    end
  end

  postgres do
    table "camera_visual_embeddings"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names frame_model_region: "camera_visual_embeddings_frame_model_region_index"

    custom_indexes do
      index [:camera_source_id, :model_id, :model_version, :timeline_ts_us],
        name: "camera_visual_embeddings_camera_model_timeline_index"

      index [:catalog_entry_id],
        name: "camera_visual_embeddings_catalog_entry_index"

      index [:model_id, :model_version],
        name: "camera_visual_embeddings_model_version_index"
    end

    custom_statements do
      statement :camera_visual_embeddings_hnsw_768_idx do
        after_tables ["camera_visual_embeddings"]

        up """
        CREATE INDEX camera_visual_embeddings_hnsw_768_idx
        ON platform.camera_visual_embeddings
        USING hnsw ((embedding::vector(768)) vector_cosine_ops)
        WITH (m = 16, ef_construction = 64)
        WHERE (embedding_dim = 768);
        """

        down """
        DROP INDEX IF EXISTS platform.camera_visual_embeddings_hnsw_768_idx;
        """
      end

      statement :camera_visual_embeddings_hnsw_512_idx do
        after_tables ["camera_visual_embeddings"]

        up """
        CREATE INDEX camera_visual_embeddings_hnsw_512_idx
        ON platform.camera_visual_embeddings
        USING hnsw ((embedding::vector(512)) vector_cosine_ops)
        WITH (m = 16, ef_construction = 64)
        WHERE (embedding_dim = 512);
        """

        down """
        DROP INDEX IF EXISTS platform.camera_visual_embeddings_hnsw_512_idx;
        """
      end

      statement :purge_visual_index_on_catalog_state_fn do
        after_tables [
          "camera_visual_index_jobs",
          "camera_visual_frames",
          "camera_visual_embeddings"
        ]

        up """
        -- serviceradar:allow-startup-maintenance: PL/pgSQL trigger function DDL only; executes zero startup table scans or row mutations.
        CREATE OR REPLACE FUNCTION platform.camera_recording_catalog_purge_visual_index()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          IF NEW.local_state = 'quarantined' OR
             (NEW.local_state = 'reclaimed' AND NEW.archive_state IN ('deleted', 'not_required')) THEN
            DELETE FROM platform.camera_visual_frames
            WHERE catalog_entry_id = NEW.id;

            DELETE FROM platform.camera_visual_embeddings
            WHERE catalog_entry_id = NEW.id;

            UPDATE platform.camera_visual_index_jobs
            SET state = 'cancelled',
                updated_at = (now() AT TIME ZONE 'utc')
            WHERE catalog_entry_id = NEW.id
              AND state IN ('pending', 'dispatched');
          END IF;

          RETURN NEW;
        END;
        $$;
        """

        down """
        DROP FUNCTION IF EXISTS platform.camera_recording_catalog_purge_visual_index();
        """
      end

      statement :purge_visual_index_on_catalog_state_trg do
        after_tables [
          "camera_visual_index_jobs",
          "camera_visual_frames",
          "camera_visual_embeddings"
        ]

        up """
        CREATE TRIGGER trg_camera_recording_catalog_purge_visual_index
        AFTER UPDATE ON platform.camera_recording_catalog
        FOR EACH ROW
        EXECUTE FUNCTION platform.camera_recording_catalog_purge_visual_index();
        """

        down """
        DROP TRIGGER IF EXISTS trg_camera_recording_catalog_purge_visual_index
        ON platform.camera_recording_catalog;
        """
      end
    end

    references do
      reference :visual_frame,
        on_delete: :delete,
        name: "camera_visual_embeddings_visual_frame_fkey"

      reference :catalog_entry,
        on_delete: :delete,
        name: "camera_visual_embeddings_catalog_entry_fkey"

      reference :camera_source,
        on_delete: :delete,
        name: "camera_visual_embeddings_camera_source_fkey"
    end

    check_constraints do
      check_constraint :embedding_dim, "camera_visual_embeddings_valid",
        check: """
        region_kind IN ('scene', 'crop') AND
        region_index >= 0 AND
        (confidence IS NULL OR (confidence >= 0.0 AND confidence <= 1.0)) AND
        (region_kind <> 'scene' OR bbox IS NULL) AND
        embedding_dim IN (512, 768) AND
        vector_dims(embedding) = embedding_dim AND
        btrim(model_id) <> '' AND
        btrim(model_version) <> ''
        """
    end
  end

  actions do
    defaults [:read]

    create :upsert_embedding do
      primary? true

      accept [
        :visual_frame_id,
        :catalog_entry_id,
        :camera_source_id,
        :stream_profile_id,
        :timeline_ts_us,
        :region_kind,
        :region_index,
        :object_class,
        :confidence,
        :bbox,
        :dominant_colors,
        :model_id,
        :model_version,
        :embedding_dim,
        :embedding
      ]

      upsert? true
      upsert_identity :frame_model_region

      upsert_fields [
        :timeline_ts_us,
        :object_class,
        :confidence,
        :bbox,
        :dominant_colors,
        :embedding_dim,
        :embedding,
        :updated_at
      ]

      validate present([
                 :visual_frame_id,
                 :catalog_entry_id,
                 :camera_source_id,
                 :stream_profile_id,
                 :timeline_ts_us,
                 :region_kind,
                 :region_index,
                 :model_id,
                 :model_version,
                 :embedding_dim,
                 :embedding
               ])

      validate ValidateVisualEmbedding
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

    attribute :visual_frame_id, :uuid do
      allow_nil? false
      public? true
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

    attribute :timeline_ts_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :region_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @region_kinds
    end

    attribute :region_index, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :object_class, :string do
      allow_nil? true
      public? true
      constraints max_length: 64
    end

    attribute :confidence, :float do
      allow_nil? true
      public? true
    end

    attribute :bbox, :map do
      allow_nil? true
      public? true
    end

    attribute :dominant_colors, {:array, :string} do
      allow_nil? false
      default []
      public? true
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

    attribute :embedding_dim, :integer do
      allow_nil? false
      public? true
      constraints min: 512, max: 768
    end

    attribute :embedding, Ash.Type.Vector do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :visual_frame, VisualFrame do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :visual_frame_id
    end

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
    identity :frame_model_region, [
      :visual_frame_id,
      :model_id,
      :model_version,
      :region_kind,
      :region_index
    ]
  end

  @doc "Allowed `region_kind` values (`:scene | :crop`)."
  @spec region_kinds() :: [atom()]
  def region_kinds, do: @region_kinds

  @doc "Supported embedding vector dimensions (`[512, 768]`)."
  @spec embedding_dims() :: [pos_integer()]
  def embedding_dims, do: @embedding_dims
end
