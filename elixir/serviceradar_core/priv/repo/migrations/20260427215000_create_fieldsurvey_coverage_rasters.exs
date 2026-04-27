defmodule ServiceRadar.Repo.Migrations.CreateFieldsurveyCoverageRasters do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:survey_coverage_rasters, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true
      add :session_id, :text, null: false
      add :user_id, :text, null: false
      add :overlay_type, :text, null: false
      add :selector_type, :text, null: false, default: "all"
      add :selector_value, :text, null: false, default: "*"

      add :cell_size_m, :float, null: false
      add :min_x, :float, null: false
      add :max_x, :float, null: false
      add :min_z, :float, null: false
      add :max_z, :float, null: false
      add :columns, :integer, null: false
      add :rows, :integer, null: false

      add :cells, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :generated_at, :timestamptz, null: false, default: fragment("now()")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :survey_coverage_rasters,
             [:session_id, :user_id, :overlay_type, :selector_type, :selector_value],
             prefix: "platform",
             name: :survey_coverage_rasters_unique_overlay_idx
           )

    create index(:survey_coverage_rasters, [:session_id, :generated_at],
             prefix: "platform",
             name: :survey_coverage_rasters_session_generated_at_idx
           )

    create index(:survey_coverage_rasters, [:user_id, :generated_at],
             prefix: "platform",
             name: :survey_coverage_rasters_user_generated_at_idx
           )
  end
end
