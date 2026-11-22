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
  end

  def down do
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
