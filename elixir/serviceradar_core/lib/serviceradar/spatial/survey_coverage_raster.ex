defmodule ServiceRadar.Spatial.SurveyCoverageRaster do
  @moduledoc """
  Backend-derived FieldSurvey coverage raster cells for review and dashboard overlays.
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "survey_coverage_rasters"
    repo ServiceRadar.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :session_id,
        :user_id,
        :overlay_type,
        :selector_type,
        :selector_value,
        :cell_size_m,
        :min_x,
        :max_x,
        :min_z,
        :max_z,
        :columns,
        :rows,
        :cells,
        :metadata,
        :generated_at
      ]
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_overlay

      accept [
        :session_id,
        :user_id,
        :overlay_type,
        :selector_type,
        :selector_value,
        :cell_size_m,
        :min_x,
        :max_x,
        :min_z,
        :max_z,
        :columns,
        :rows,
        :cells,
        :metadata,
        :generated_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :session_id, :string, allow_nil?: false
    attribute :user_id, :string, allow_nil?: false
    attribute :overlay_type, :string, allow_nil?: false
    attribute :selector_type, :string, allow_nil?: false, default: "all"
    attribute :selector_value, :string, allow_nil?: false, default: "*"

    attribute :cell_size_m, :float, allow_nil?: false
    attribute :min_x, :float, allow_nil?: false
    attribute :max_x, :float, allow_nil?: false
    attribute :min_z, :float, allow_nil?: false
    attribute :max_z, :float, allow_nil?: false
    attribute :columns, :integer, allow_nil?: false
    attribute :rows, :integer, allow_nil?: false

    attribute :cells, :map, allow_nil?: false, default: %{}
    attribute :metadata, :map, allow_nil?: false, default: %{}
    attribute :generated_at, :utc_datetime_usec, allow_nil?: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_overlay, [
      :session_id,
      :user_id,
      :overlay_type,
      :selector_type,
      :selector_value
    ]
  end
end
