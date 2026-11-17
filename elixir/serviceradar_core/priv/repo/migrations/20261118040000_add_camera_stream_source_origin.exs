defmodule ServiceRadar.Repo.Migrations.AddCameraStreamSourceOrigin do
  @moduledoc """
  Adds the two non-secret stream facts camera inventory keeps once the agent
  resolves stream addresses itself (Stage 3 of resolve-camera-stream-sources-at-edge,
  design D3):

    * `camera_stream_profiles.source_origin`: the stream's origin
      (`scheme://host[:port]`), never a path, alias or userinfo.
    * `camera_sources.discovery_assignment_id`: the plugin assignment whose
      host-stamped result reported the camera, so a relay can ask that
      assignment to resolve the address. Deleting the assignment clears it.

  `camera_sources.source_url` and `camera_stream_profiles.source_url_override`
  stay in place here; the stage 3 stream secret scrub empties them and Stage 4
  drops them. Both tables hold one row per camera or profile, so the column adds
  and the index build hold their locks briefly.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:camera_stream_profiles, prefix: @prefix) do
      add :source_origin, :text
    end

    alter table(:camera_sources, prefix: @prefix) do
      add :discovery_assignment_id,
          references(:plugin_assignments,
            type: :uuid,
            prefix: @prefix,
            on_delete: :nilify_all
          )
    end

    create index(:camera_sources, [:discovery_assignment_id],
             prefix: @prefix,
             where: "discovery_assignment_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:camera_sources, [:discovery_assignment_id], prefix: @prefix)

    alter table(:camera_sources, prefix: @prefix) do
      remove :discovery_assignment_id
    end

    alter table(:camera_stream_profiles, prefix: @prefix) do
      remove :source_origin
    end
  end
end
