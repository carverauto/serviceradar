defmodule ServiceRadar.Repo.Migrations.CreateFieldsurveyReviewPreferences do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:fieldsurvey_review_preferences, primary_key: false, prefix: "platform") do
      add(:id, :uuid, primary_key: true)
      add(:user_id, :text, null: false)
      add(:session_id, :text, null: false)
      add(:favorite, :boolean, null: false, default: false)
      add(:default_view, :boolean, null: false, default: false)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:fieldsurvey_review_preferences, [:user_id, :session_id],
        prefix: "platform",
        name: :fieldsurvey_review_preferences_user_session_idx
      )
    )

    create(
      index(:fieldsurvey_review_preferences, [:user_id, :favorite],
        prefix: "platform",
        name: :fieldsurvey_review_preferences_user_favorite_idx
      )
    )

    execute(
      """
      CREATE UNIQUE INDEX fieldsurvey_review_preferences_user_default_idx
      ON platform.fieldsurvey_review_preferences (user_id)
      WHERE default_view = true;
      """,
      "DROP INDEX IF EXISTS platform.fieldsurvey_review_preferences_user_default_idx;"
    )
  end
end
