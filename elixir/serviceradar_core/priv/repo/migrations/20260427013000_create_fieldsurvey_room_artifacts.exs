defmodule ServiceRadar.Repo.Migrations.CreateFieldsurveyRoomArtifacts do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:survey_room_artifacts, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true
      add :session_id, :text, null: false
      add :user_id, :text, null: false
      add :artifact_type, :text, null: false
      add :content_type, :text, null: false
      add :object_key, :text, null: false
      add :byte_size, :bigint, null: false
      add :sha256, :text, null: false
      add :captured_at, :timestamptz
      add :metadata, :map, null: false, default: %{}
      add :uploaded_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:survey_room_artifacts, [:object_key],
             prefix: "platform",
             name: :survey_room_artifacts_object_key_idx
           )

    create index(:survey_room_artifacts, [:session_id, :uploaded_at],
             prefix: "platform",
             name: :survey_room_artifacts_session_uploaded_at_idx
           )

    create index(:survey_room_artifacts, [:user_id, :uploaded_at],
             prefix: "platform",
             name: :survey_room_artifacts_user_uploaded_at_idx
           )
  end
end
