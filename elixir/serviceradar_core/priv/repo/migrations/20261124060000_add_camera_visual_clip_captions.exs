defmodule ServiceRadar.Repo.Migrations.AddCameraVisualClipCaptions do
  @moduledoc """
  Adds `platform.camera_visual_clip_captions` for event-triggered multi-frame VLM
  action captions with PostgreSQL full-text (`caption_tsv` + GIN) and pgvector
  cosine (`caption_embedding` + HNSW) indexing, strictly coupled to
  `platform.camera_recording_catalog` quarantine and terminal deletion lifecycles.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    execute("""
    -- serviceradar:allow-startup-maintenance: IMMUTABLE SQL helper DDL only; executes zero startup table scans or row mutations.
    CREATE OR REPLACE FUNCTION platform.camera_caption_tsvector(
      caption_text text,
      action_tags text[]
    )
    RETURNS tsvector
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      SELECT to_tsvector(
        'english',
        coalesce(caption_text, '') || ' ' || coalesce(array_to_string(action_tags, ' '), '')
      );
    $$;
    """)

    create table(:camera_visual_clip_captions, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :camera_source_id,
        references(:camera_sources,
          column: :id,
          name: "camera_visual_clip_captions_camera_source_fkey",
          type: :uuid,
          prefix: "platform",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:stream_profile_id, :uuid, null: false)

      add(
        :catalog_entry_id,
        references(:camera_recording_catalog,
          column: :id,
          name: "camera_visual_clip_captions_catalog_entry_fkey",
          type: :uuid,
          prefix: "platform",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :visual_frame_id,
        references(:camera_visual_frames,
          column: :id,
          name: "camera_visual_clip_captions_visual_frame_fkey",
          type: :uuid,
          prefix: "platform",
          on_delete: :nilify_all
        ),
        null: true
      )

      add(:start_us, :bigint, null: false)
      add(:end_us, :bigint, null: false)
      add(:time_basis, :text, null: false, default: "received")
      add(:caption_text, :text, null: false)
      add(:action_tags, {:array, :text}, null: false, default: [])
      add(:caption_embedding, :vector, null: true)
      add(:embedding_dim, :bigint, null: true)
      add(:vlm_model_id, :text, null: false)
      add(:prompt_version, :text, null: false, default: "v1")
      add(:embedder_model_id, :text, null: true)
      add(:embedder_model_version, :text, null: true)

      add(:generated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    execute("""
    ALTER TABLE platform.camera_visual_clip_captions
    ADD COLUMN caption_tsv tsvector
    GENERATED ALWAYS AS (platform.camera_caption_tsvector(caption_text, action_tags)) STORED;
    """)

    create(
      unique_index(
        :camera_visual_clip_captions,
        [:catalog_entry_id, :start_us, :end_us, :vlm_model_id, :prompt_version],
        name: "camera_visual_clip_captions_entry_span_model_index",
        prefix: "platform"
      )
    )

    create(
      index(
        :camera_visual_clip_captions,
        [:camera_source_id, :start_us, :end_us],
        name: "camera_visual_clip_captions_camera_span_index",
        prefix: "platform"
      )
    )

    create(
      index(
        :camera_visual_clip_captions,
        [:catalog_entry_id],
        name: "camera_visual_clip_captions_catalog_entry_index",
        prefix: "platform"
      )
    )

    create(
      constraint(:camera_visual_clip_captions, :camera_visual_clip_captions_valid,
        check: """
        end_us >= start_us AND
        time_basis IN ('received', 'camera_reported') AND
        btrim(caption_text) <> '' AND octet_length(caption_text) <= 4096 AND
        btrim(vlm_model_id) <> '' AND
        btrim(prompt_version) <> '' AND
        (caption_embedding IS NULL OR (embedding_dim IN (512, 768, 1152) AND vector_dims(caption_embedding) = embedding_dim))
        """,
        prefix: "platform"
      )
    )

    execute("""
    CREATE INDEX camera_visual_clip_captions_tsv_gin_idx
    ON platform.camera_visual_clip_captions
    USING gin (caption_tsv);
    """)

    execute("""
    CREATE INDEX camera_visual_clip_captions_tags_gin_idx
    ON platform.camera_visual_clip_captions
    USING gin (action_tags);
    """)

    execute("""
    CREATE INDEX camera_visual_clip_captions_hnsw_768_idx
    ON platform.camera_visual_clip_captions
    USING hnsw ((caption_embedding::vector(768)) vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE (caption_embedding IS NOT NULL AND embedding_dim = 768);
    """)

    execute("""
    CREATE INDEX camera_visual_clip_captions_hnsw_512_idx
    ON platform.camera_visual_clip_captions
    USING hnsw ((caption_embedding::vector(512)) vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE (caption_embedding IS NOT NULL AND embedding_dim = 512);
    """)

    execute("""
    -- serviceradar:allow-startup-maintenance: PL/pgSQL trigger function DDL only; executes zero startup table scans or row mutations.
    CREATE OR REPLACE FUNCTION platform.camera_recording_catalog_purge_visual_clip_captions()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.local_state = 'quarantined' OR
         (NEW.local_state = 'reclaimed' AND NEW.archive_state IN ('deleted', 'not_required')) THEN
        DELETE FROM platform.camera_visual_clip_captions
        WHERE catalog_entry_id = NEW.id;
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    execute("""
    CREATE TRIGGER trg_camera_recording_catalog_purge_visual_clip_captions
    AFTER UPDATE ON platform.camera_recording_catalog
    FOR EACH ROW
    EXECUTE FUNCTION platform.camera_recording_catalog_purge_visual_clip_captions();
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS trg_camera_recording_catalog_purge_visual_clip_captions
    ON platform.camera_recording_catalog;
    """)

    execute("""
    DROP FUNCTION IF EXISTS platform.camera_recording_catalog_purge_visual_clip_captions();
    """)

    execute("DROP INDEX IF EXISTS platform.camera_visual_clip_captions_hnsw_512_idx;")
    execute("DROP INDEX IF EXISTS platform.camera_visual_clip_captions_hnsw_768_idx;")
    execute("DROP INDEX IF EXISTS platform.camera_visual_clip_captions_tags_gin_idx;")
    execute("DROP INDEX IF EXISTS platform.camera_visual_clip_captions_tsv_gin_idx;")

    drop_if_exists(
      constraint(:camera_visual_clip_captions, :camera_visual_clip_captions_valid,
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:camera_visual_clip_captions, [:catalog_entry_id],
        name: "camera_visual_clip_captions_catalog_entry_index",
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:camera_visual_clip_captions, [:camera_source_id, :start_us, :end_us],
        name: "camera_visual_clip_captions_camera_span_index",
        prefix: "platform"
      )
    )

    drop_if_exists(
      unique_index(
        :camera_visual_clip_captions,
        [:catalog_entry_id, :start_us, :end_us, :vlm_model_id, :prompt_version],
        name: "camera_visual_clip_captions_entry_span_model_index",
        prefix: "platform"
      )
    )

    drop(table(:camera_visual_clip_captions, prefix: "platform"))

    execute("DROP FUNCTION IF EXISTS platform.camera_caption_tsvector(text, text[]);")
  end
end
