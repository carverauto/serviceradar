defmodule ServiceRadar.Repo.Migrations.CreateFieldsurveySessionMetadata do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:survey_session_metadata, primary_key: false, prefix: "platform") do
      add :session_id, :text, primary_key: true
      add :user_id, :text, null: false
      add :site_id, :text
      add :site_name, :text
      add :building_id, :text
      add :building_name, :text
      add :floor_id, :text
      add :floor_name, :text
      add :floor_index, :integer
      add :tags, {:array, :text}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:survey_session_metadata, [:user_id, :site_id, :building_id, :floor_index],
             prefix: "platform",
             name: :survey_session_metadata_user_location_idx
           )

    create index(:survey_session_metadata, [:user_id, :updated_at],
             prefix: "platform",
             name: :survey_session_metadata_user_updated_idx
           )

    execute(
      "CREATE INDEX survey_session_metadata_tags_gin_idx ON platform.survey_session_metadata USING GIN (tags);",
      "DROP INDEX IF EXISTS platform.survey_session_metadata_tags_gin_idx;"
    )
  end
end
