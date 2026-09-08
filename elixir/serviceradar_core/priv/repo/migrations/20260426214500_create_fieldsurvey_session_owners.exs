defmodule ServiceRadar.Repo.Migrations.CreateFieldSurveySessionOwners do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:survey_session_owners, primary_key: false, prefix: "platform") do
      add :session_id, :text, primary_key: true
      add :user_id, :text, null: false
      add :claimed_at, :timestamptz, null: false, default: fragment("now()")
      add :last_seen_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:survey_session_owners, [:user_id, :last_seen_at],
             prefix: "platform",
             name: :survey_session_owners_user_seen_idx
           )
  end
end
