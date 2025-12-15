defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Categories do
  @moduledoc false

  use Phoenix.LiveComponent

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  alias ServiceRadarWebNGWeb.SRQL.Viz

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_auto_viz: 1]

  @impl true
  def id, do: "categories"

  @impl true
  def title, do: "Categories"

  @impl true
  def supports?(%{"results" => results}) when is_list(results) do
    match?({:categories, _}, Viz.infer(results))
  end

  def supports?(_), do: false

  @impl true
  def build(%{"results" => results}) when is_list(results) do
    case Viz.infer(results) do
      {:categories, _} = viz -> {:ok, %{viz: viz}}
      _ -> {:error, :not_categories}
    end
  end

  def build(_), do: {:error, :invalid_response}

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
      <.srql_auto_viz viz={@viz} />
    </div>
    """
  end
end
