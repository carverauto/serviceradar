defmodule ServiceRadar.Repo.Migrations.AddCameraRelaySessions do
  use Ecto.Migration

  def change do
    create table(:camera_relay_sessions, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true

      add :camera_source_id,
          references(:camera_sources,
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false

      add :stream_profile_id,
          references(:camera_stream_profiles,
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false

      add :agent_id, :text, null: false
      add :gateway_id, :text, null: false
      add :status, :text, null: false
      add :command_id, :uuid
      add :lease_token, :text
      add :lease_expires_at, :utc_datetime_usec
      add :media_ingest_id, :text
      add :requested_by, :text
      add :close_reason, :text
      add :failure_reason, :text
      add :opened_at, :utc_datetime_usec
      add :activated_at, :utc_datetime_usec
      add :close_requested_at, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:camera_relay_sessions, [:camera_source_id],
             prefix: "platform"
           )

    create index(:camera_relay_sessions, [:stream_profile_id],
             prefix: "platform"
           )

    create index(:camera_relay_sessions, [:agent_id, :status],
             prefix: "platform"
           )

    create index(:camera_relay_sessions, [:gateway_id, :status],
             prefix: "platform"
           )

    create index(:camera_relay_sessions, [:lease_expires_at],
             prefix: "platform"
           )
  end
end
