defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.GraphResult do
  @moduledoc false

  use Phoenix.LiveComponent

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  @max_preview 20

  @impl true
  def id, do: "graph_result"

  @impl true
  def title, do: "Graph"

  @impl true
  def supports?(%{"viz" => %{"columns" => columns}, "results" => results})
      when is_list(columns) and is_list(results) do
    graphish_viz?(columns) or graphish_results?(results)
  end

  def supports?(_), do: false

  @impl true
  def build(%{"results" => results} = _srql_response) when is_list(results) do
    {:ok,
     %{
       max_preview: @max_preview,
       items: Enum.take(results, @max_preview),
       summary: summarize(results)
     }}
  end

  def build(_), do: {:error, :invalid_response}

  defp graphish_viz?(columns) do
    Enum.any?(columns, fn
      %{"name" => "result", "type" => "jsonb"} -> true
      %{"name" => "result"} -> true
      _ -> false
    end)
  end

  defp graphish_results?(results) do
    Enum.any?(results, fn
      %{"nodes" => _nodes, "edges" => _edges} -> true
      %{"vertices" => _v, "edges" => _e} -> true
      %{"result" => %{} = _} -> true
      _ -> false
    end)
  end

  defp summarize(results) do
    Enum.reduce(results, %{nodes: 0, edges: 0}, fn item, acc ->
      case item do
        %{"nodes" => nodes, "edges" => edges} when is_list(nodes) and is_list(edges) ->
          %{acc | nodes: acc.nodes + length(nodes), edges: acc.edges + length(edges)}

        %{"vertices" => nodes, "edges" => edges} when is_list(nodes) and is_list(edges) ->
          %{acc | nodes: acc.nodes + length(nodes), edges: acc.edges + length(edges)}

        _ ->
          acc
      end
    end)
  end

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:panel_assigns]))
      |> assign(panel_assigns || %{})

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">Graph</div>
            <div class="text-xs text-base-content/70">
              Nodes: <span class="font-mono">{@summary.nodes}</span>
              <span class="opacity-60">·</span> Edges: <span class="font-mono">{@summary.edges}</span>
            </div>
          </div>
        </:header>

        <div class="text-xs text-base-content/70 mb-3">
          Preview of the first {@max_preview} graph result rows.
        </div>

        <div class="rounded-xl border border-base-200 bg-base-100 p-3 overflow-x-auto">
          <pre class="text-xs leading-relaxed"><%= Jason.encode!(@items, pretty: true) %></pre>
        </div>
      </.ui_panel>
    </div>
    """
  end
end
