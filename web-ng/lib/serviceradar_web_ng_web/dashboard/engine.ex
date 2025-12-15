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
    panel = build_panel(srql_response)
    [panel]
  end

  def build_panels(_), do: [fallback_panel(%{"results" => []})]

  defp build_panel(%{} = srql_response) do
    plugins = Registry.plugins()

    Enum.reduce_while(plugins, nil, fn plugin, _acc ->
      if Code.ensure_loaded?(plugin) and plugin.supports?(srql_response) do
        {:halt, plugin_panel(plugin, srql_response)}
      else
        {:cont, nil}
      end
    end) || fallback_panel(srql_response)
  end

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
        fallback_panel(srql_response)
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
