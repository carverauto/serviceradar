defmodule ServiceRadarWebNG.Dashboards.DefinitionSerializer do
  @moduledoc """
  Serializes an authored dashboard and its panels to the definition format.

  The definition format is the portable representation a dashboard can be exported
  to and imported from. It carries the dashboard's content fields and its ordered
  panels, each carrying its query, visual type, bindings and layout.

  ## Fields outside the format

  The following fields are deliberately excluded so that "equivalent" has a precise
  meaning: two dashboards are equivalent over the format when every field the
  serializer emits is identical.

  **Dashboard-level exclusions:**
  - `:id` — database identifier, meaningless across installations
  - `:dashboard_ref` — collision-avoiding display number, reassigned on import
  - `:inserted_at`, `:updated_at`, `:archived_at` — timestamps
  - `:owner_id` — ownership; the importing installation applies its own
  - `:visibility`, `:status` — operational state set by the importing installation

  **Panel-level exclusions:**
  - `:id` — database identifier
  - `:dashboard_id` — foreign key to the containing dashboard
  - `:inserted_at`, `:updated_at` — timestamps
  - `:builder_state` — transient UI state the builder reconstructs from the query
  - `:field_metadata` — cached display hints, repopulated on load
  - `:dataset_key` — inferred from the query by the compiler
  - `:refresh_interval_seconds`, `:metadata` — installation-local configuration

  **Associated collections excluded entirely:** access grants and report schedules
  reference principals and schedules that need not exist in an importing
  installation.
  """

  @current_version 1

  @doc """
  Serializes a dashboard struct (with `:panels` loaded) to a definition map.

  The returned map is ready to encode with `Jason.encode!/1` and will pass
  `Definition.validate/2`.
  """
  @spec serialize(map()) :: map()
  def serialize(dashboard) do
    panels =
      dashboard
      |> Map.get(:panels, [])
      |> List.wrap()
      |> Enum.sort_by(& &1.position)
      |> Enum.with_index()
      |> Enum.map(fn {panel, idx} -> serialize_panel(panel, idx) end)

    %{
      "version" => @current_version,
      "slug" => dashboard.slug,
      "title" => dashboard.title,
      "description" => dashboard.description,
      "default_time_range" => dashboard.default_time_range,
      "metadata" => dashboard.metadata || %{},
      "variables" => dashboard.variables || %{},
      "panels" => panels
    }
  end

  defp serialize_panel(panel, fallback_position) do
    %{
      "title" => panel.title,
      "srql_query" => panel.srql_query,
      "visual_type" => to_string(panel.visual_type),
      "data_binding" => panel.data_binding || %{},
      "display_config" => panel.display_config || %{},
      "visual_config" => panel.visual_config || %{},
      "layout" => panel.layout,
      "position" => panel.position || fallback_position
    }
  end
end
