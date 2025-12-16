defmodule ServiceRadarWebNGWeb.Dashboard.Engine do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Registry

  @type srql_response :: map()

  @type panel :: %{
          id: String.t(),
          plugin: module(),
          title: String.t(),
          assigns: map()
        }

  def build_panels(%{} = srql_response) do
    plugins = Registry.plugins()

    {table_plugins, other_plugins} =
      Enum.split_with(plugins, fn plugin ->
        plugin == ServiceRadarWebNGWeb.Dashboard.Plugins.Table
      end)

    other_panels =
      other_plugins
      |> Enum.filter(fn plugin ->
        Code.ensure_loaded?(plugin) and plugin.supports?(srql_response)
      end)
      |> Enum.map(&plugin_panel(&1, srql_response))
      |> Enum.reject(&is_nil/1)

    table_panel =
      case table_plugins do
        [table_plugin | _] -> plugin_panel(table_plugin, srql_response)
        _ -> nil
      end

    cond do
      other_panels == [] ->
        case table_panel do
          %{} -> [table_panel]
          _ -> [fallback_panel(srql_response)]
        end

      is_map(table_panel) ->
        other_panels ++ [table_panel]

      true ->
        other_panels
    end
  end

  def build_panels(_), do: [fallback_panel(%{"results" => []})]

  defp plugin_panel(plugin, srql_response) do
    base = %{
      id: plugin_id(plugin),
      plugin: plugin,
      title: plugin_title(plugin),
      assigns: %{}
    }

    case plugin.build(srql_response) do
      {:ok, assigns} when is_map(assigns) ->
        %{base | assigns: assigns}

      _ ->
        nil
    end
  end

  defp fallback_panel(srql_response) do
    plugin_panel(ServiceRadarWebNGWeb.Dashboard.Plugins.Table, srql_response)
  end

  defp plugin_id(plugin) do
    if function_exported?(plugin, :id, 0) do
      plugin.id()
    else
      plugin |> Module.split() |> List.last() |> to_string()
    end
  end

  defp plugin_title(plugin) do
    if function_exported?(plugin, :title, 0) do
      plugin.title()
    else
      plugin |> Module.split() |> List.last() |> to_string()
    end
  end
end
