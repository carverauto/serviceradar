defmodule ServiceRadar.Repo.Migrations.AddCameraClipThumbnails do
  @moduledoc """
  Adds bounded nullable `thumbnail_jpeg` bytea columns (<= 64 KiB) to
  `platform.camera_recording_catalog` and `platform.camera_visual_frames`.
  """

  use Ecto.Migration

  def up do
    alter table(:camera_recording_catalog, prefix: "platform") do
      add(:thumbnail_jpeg, :binary)
    end

    create(
      constraint(
        :camera_recording_catalog,
        :camera_recording_catalog_thumbnail_jpeg_size,
        check: "thumbnail_jpeg IS NULL OR octet_length(thumbnail_jpeg) <= 65536",
        prefix: "platform"
      )
    )

    alter table(:camera_visual_frames, prefix: "platform") do
      add(:thumbnail_jpeg, :binary)
    end

    create(
      constraint(
        :camera_visual_frames,
        :camera_visual_frames_thumbnail_jpeg_size,
        check: "thumbnail_jpeg IS NULL OR octet_length(thumbnail_jpeg) <= 65536",
        prefix: "platform"
      )
    )

    execute("""
    -- serviceradar:allow-startup-maintenance: PL/pgSQL trigger function DDL only; executes zero startup table scans or row mutations.
    CREATE OR REPLACE FUNCTION platform.camera_recording_catalog_purge_thumbnail()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.local_state = 'quarantined' OR
         (NEW.local_state = 'reclaimed' AND NEW.archive_state IN ('deleted', 'not_required')) THEN
        NEW.thumbnail_jpeg := NULL;
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    execute("""
    CREATE TRIGGER trg_camera_recording_catalog_purge_thumbnail
    BEFORE UPDATE ON platform.camera_recording_catalog
    FOR EACH ROW
    EXECUTE FUNCTION platform.camera_recording_catalog_purge_thumbnail();
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS trg_camera_recording_catalog_purge_thumbnail
    ON platform.camera_recording_catalog;
    """)

    execute("""
    DROP FUNCTION IF EXISTS platform.camera_recording_catalog_purge_thumbnail();
    """)

    drop_if_exists(
      constraint(
        :camera_visual_frames,
        :camera_visual_frames_thumbnail_jpeg_size,
        prefix: "platform"
      )
    )

    alter table(:camera_visual_frames, prefix: "platform") do
      remove(:thumbnail_jpeg)
    end

    drop_if_exists(
      constraint(
        :camera_recording_catalog,
        :camera_recording_catalog_thumbnail_jpeg_size,
        prefix: "platform"
      )
    )

    alter table(:camera_recording_catalog, prefix: "platform") do
      remove(:thumbnail_jpeg)
    end
  end
end
