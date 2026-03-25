defmodule ServiceRadar.Repo.Migrations.AddCameraInventoryTables do
  @moduledoc """
  Adds normalized camera inventory tables for relay source resolution.
  """

  use Ecto.Migration

  def up do
    create table(:camera_sources, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :device_uid, :text, null: false
      add :vendor, :text, null: false
      add :vendor_camera_id, :text, null: false
      add :display_name, :text
      add :source_url, :text
      add :assigned_agent_id, :text
      add :assigned_gateway_id, :text
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:camera_sources, [:vendor, :vendor_camera_id],
             prefix: "platform",
             name: "camera_sources_vendor_camera_uidx"
           )

    create index(:camera_sources, [:device_uid],
             prefix: "platform",
             name: "camera_sources_device_uid_idx"
           )

    create index(:camera_sources, [:assigned_agent_id],
             prefix: "platform",
             name: "camera_sources_assigned_agent_idx"
           )

    create table(:camera_stream_profiles, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :camera_source_id,
          references(:camera_sources,
            column: :id,
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false

      add :profile_name, :text, null: false
      add :vendor_profile_id, :text
      add :source_url_override, :text
      add :rtsp_transport, :text
      add :codec_hint, :text
      add :container_hint, :text, default: "annexb"
      add :relay_eligible, :boolean, null: false, default: true
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:camera_stream_profiles, [:camera_source_id, :profile_name],
             prefix: "platform",
             name: "camera_stream_profiles_source_profile_uidx"
           )

    create index(:camera_stream_profiles, [:camera_source_id],
             prefix: "platform",
             name: "camera_stream_profiles_source_idx"
           )

    create index(:camera_stream_profiles, [:relay_eligible],
             prefix: "platform",
             name: "camera_stream_profiles_relay_eligible_idx"
           )
  end

  def down do
    drop_if_exists index(:camera_stream_profiles, [:relay_eligible],
                     prefix: "platform",
                     name: "camera_stream_profiles_relay_eligible_idx"
                   )

    drop_if_exists index(:camera_stream_profiles, [:camera_source_id],
                     prefix: "platform",
                     name: "camera_stream_profiles_source_idx"
                   )

    drop_if_exists unique_index(:camera_stream_profiles, [:camera_source_id, :profile_name],
                     prefix: "platform",
                     name: "camera_stream_profiles_source_profile_uidx"
                   )

    drop_if_exists table(:camera_stream_profiles, prefix: "platform")

    drop_if_exists index(:camera_sources, [:assigned_agent_id],
                     prefix: "platform",
                     name: "camera_sources_assigned_agent_idx"
                   )

    drop_if_exists index(:camera_sources, [:device_uid],
                     prefix: "platform",
                     name: "camera_sources_device_uid_idx"
                   )

    drop_if_exists unique_index(:camera_sources, [:vendor, :vendor_camera_id],
                     prefix: "platform",
                     name: "camera_sources_vendor_camera_uidx"
                   )

    drop_if_exists table(:camera_sources, prefix: "platform")
  end
end
