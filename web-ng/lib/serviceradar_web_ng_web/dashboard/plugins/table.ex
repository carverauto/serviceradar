defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Table do
  @moduledoc false

  use Phoenix.LiveComponent

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_results_table: 1]
  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  @impl true
  def id, do: "table"

  @impl true
  def title, do: "Table"

  @impl true
  def supports?(_srql_response), do: true

  @impl true
  def build(%{} = srql_response) do
    results =
      srql_response
      |> Map.get("results", [])
      |> normalize_results()

    {:ok, %{results: results}}
  end

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:panel_assigns]))
      |> assign(panel_assigns || %{})

    {:ok, socket}
  end

  defp normalize_results(results) when is_list(results) do
    Enum.map(results, fn
      %{} = row -> row
      value -> %{"value" => value}
    end)
  end

  defp normalize_results(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="text-sm font-semibold">Table</div>
        </:header>

        <.srql_results_table id={"panel-#{@id}-table"} rows={@results} empty_message="No results." />
      </.ui_panel>
    </div>
    """
  end
end
