defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries do
  @moduledoc false

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  use Phoenix.LiveComponent

  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.ChartCard
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.CombinedChartCard
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Spec
  alias ServiceRadarWebNGWeb.SRQL.Viz

  @chart_width 800
  @chart_height 140
  @chart_pad 8

  @impl true
  def id, do: "timeseries"

  @impl true
  def title, do: "Timeseries"

  @impl true
  def supports?(%{"viz" => %{"suggestions" => suggestions}}) when is_list(suggestions) do
    Enum.any?(suggestions, fn
      %{"kind" => "timeseries"} -> true
      _ -> false
    end)
  end

  def supports?(%{"results" => results}) when is_list(results) do
    match?({:timeseries, _}, Viz.infer(results))
  end

  def supports?(_), do: false

  @impl true
  def build(%{"results" => results, "viz" => viz} = _srql_response) when is_list(results) and is_map(viz) do
    with {:ok, spec} <- Spec.parse_timeseries_spec(viz),
         {:ok, series_points} <- Spec.extract_series_points(results, spec) do
      {:ok, %{spec: spec, series_points: series_points}}
    end
  end

  def build(%{"results" => results} = _srql_response) when is_list(results) do
    case Spec.infer_timeseries_spec(results) do
      {:ok, spec} ->
        with {:ok, series_points} <- Spec.extract_series_points(results, spec) do
          {:ok, %{spec: spec, series_points: series_points}}
        end

      _ ->
        {:error, :invalid_response}
    end
  end

  def build(_), do: {:error, :invalid_response}

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    compact = Map.get(panel_assigns || %{}, :compact, false)
    max_speed = Map.get(panel_assigns || %{}, :max_speed_bytes_per_sec)
    chart_mode = Map.get(panel_assigns || %{}, :chart_mode, :single)
    combine_all_series = Map.get(panel_assigns || %{}, :combine_all_series, false)
    combined_title = Map.get(panel_assigns || %{}, :combined_title)
    rate_mode = Map.get(panel_assigns || %{}, :rate_mode, :none)
    series_points = series_points_from_assigns(assigns, panel_assigns)
    spec = Spec.fetch_panel_value(panel_assigns, :spec, Map.get(assigns, :spec))

    series_points =
      case rate_mode do
        :counter -> Metrics.counter_rates(series_points, max_speed)
        _ -> series_points
      end

    socket =
      socket
      |> assign(Map.delete(assigns, :panel_assigns))
      |> assign(panel_assigns)
      |> assign(:compact, compact)
      |> assign(:series_points, series_points)
      |> assign(:spec, spec)
      |> assign(:max_speed_bytes_per_sec, max_speed)
      |> assign(:chart_mode, chart_mode)
      |> assign(:combine_all_series, combine_all_series)
      |> assign(:combined_title, combined_title)
      |> assign(:rate_mode, rate_mode)
      |> assign(:chart_width, @chart_width)
      |> assign(:chart_height, @chart_height)
      |> assign(:chart_pad, @chart_pad)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    compact = Map.get(assigns, :compact, false)
    series_points = assigns.series_points || []
    max_speed = Map.get(assigns, :max_speed_bytes_per_sec)
    chart_mode = Map.get(assigns, :chart_mode, :single)
    combine_all_series = Map.get(assigns, :combine_all_series, false)
    combined_title = Map.get(assigns, :combined_title, "Combined")

    series_data =
      SeriesData.build_series_data(
        series_points,
        Map.get(assigns, :spec),
        Map.get(assigns, :rate_mode, :none),
        compact,
        max_speed
      )

    {combined_charts, individual_series} =
      SeriesData.resolve_chart_groups(
        series_data,
        combine_all_series,
        chart_mode,
        max_speed,
        compact,
        combined_title
      )

    assigns =
      assigns
      |> assign(:compact, compact)
      |> assign(:series_count, length(series_points))
      |> assign(:series_data, individual_series)
      |> assign(:combined_charts, combined_charts)
      |> assign(:first_dt, Points.first_dt(series_points))
      |> assign(:last_dt, Points.last_dt(series_points))

    render_chart(assigns, compact)
  end

  defp series_points_from_assigns(assigns, panel_assigns) do
    cond do
      is_map(panel_assigns) and Spec.fetch_panel_value(panel_assigns, :series_points) != nil ->
        Spec.fetch_panel_value(panel_assigns, :series_points) || []

      is_map(panel_assigns) and Spec.fetch_panel_value(panel_assigns, :series) != nil ->
        Spec.series_to_points(Spec.fetch_panel_value(panel_assigns, :series))

      true ->
        Map.get(assigns, :series_points, [])
    end
  end

  defp render_chart(assigns, true), do: render_compact(assigns)
  defp render_chart(assigns, false), do: render_full(assigns)

  defp render_compact(assigns) do
    ~H"""
    <div id={"panel-#{@id}"} class="p-4">
      <div class={[
        "grid gap-3",
        @series_count > 1 && "grid-cols-1 lg:grid-cols-2 xl:grid-cols-3",
        @series_count == 1 && "grid-cols-1"
      ]}>
        <%= for combined <- @combined_charts do %>
          <CombinedChartCard.combined_chart_card
            id={@id}
            data={combined}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={true}
          />
        <% end %>
        <%= for data <- @series_data do %>
          <ChartCard.chart_card
            id={@id}
            data={data}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={true}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp render_full(assigns) do
    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">{@title || "Timeseries"}</div>
          </div>
          <div class="text-xs text-base-content/50 font-mono">
            <span :if={is_struct(@first_dt, DateTime)}>{Points.dt_label(@first_dt)}</span>
            <span class="px-1">→</span>
            <span :if={is_struct(@last_dt, DateTime)}>{Points.dt_label(@last_dt)}</span>
          </div>
        </:header>

        <%= for combined <- @combined_charts do %>
          <CombinedChartCard.combined_chart_card
            id={@id}
            data={combined}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={false}
          />
        <% end %>

        <div
          :if={@series_data != []}
          class={[
            "grid gap-4",
            length(@series_data) > 1 && "grid-cols-1 md:grid-cols-2",
            length(@series_data) <= 1 && "grid-cols-1"
          ]}
        >
          <%= for data <- @series_data do %>
            <ChartCard.chart_card
              id={@id}
              data={data}
              chart_width={@chart_width}
              chart_height={@chart_height}
              chart_pad={@chart_pad}
              compact={false}
            />
          <% end %>
        </div>
      </.ui_panel>
    </div>
    """
  end
end
