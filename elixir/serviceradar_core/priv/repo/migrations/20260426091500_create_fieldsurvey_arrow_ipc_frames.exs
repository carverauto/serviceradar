defmodule ServiceRadar.Repo.Migrations.CreateFieldSurveyArrowIpcFrames do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:survey_arrow_ipc_frames, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :session_id, :text, null: false
      add :stream_type, :text, null: false
      add :user_id, :text
      add :frame_index, :bigint, null: false
      add :byte_size, :integer, null: false
      add :row_count, :integer, null: false, default: 0
      add :decode_status, :text, null: false
      add :decode_error, :text
      add :payload_sha256, :binary, null: false
      add :payload, :binary, null: false
      add :received_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false
    end

    execute "ALTER TABLE platform.survey_arrow_ipc_frames ADD PRIMARY KEY (received_at, id);"

    execute(
      "SELECT create_hypertable('platform.survey_arrow_ipc_frames', 'received_at', if_not_exists => TRUE);"
    )

    create index(:survey_arrow_ipc_frames, [:session_id, :stream_type, :received_at],
             prefix: "platform",
             name: :survey_arrow_ipc_frames_session_stream_time_idx
           )

    create index(:survey_arrow_ipc_frames, [:payload_sha256],
             prefix: "platform",
             name: :survey_arrow_ipc_frames_payload_sha256_idx
           )
  end

  def down do
    drop table(:survey_arrow_ipc_frames, prefix: "platform")
  end
end
