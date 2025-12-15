defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries do
  @moduledoc false

  use Phoenix.LiveComponent

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  @max_series 6
  @max_points 200

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

  def supports?(_), do: false

  @impl true
  def build(%{"results" => results, "viz" => viz} = _srql_response)
      when is_list(results) and is_map(viz) do
    with {:ok, spec} <- parse_timeseries_spec(viz),
         {:ok, series_points} <- extract_series_points(results, spec) do
      {:ok, %{spec: spec, series_points: series_points}}
    end
  end

  def build(_), do: {:error, :invalid_response}

  defp parse_timeseries_spec(%{"suggestions" => suggestions}) when is_list(suggestions) do
    suggestion =
      Enum.find(suggestions, fn
        %{"kind" => "timeseries"} -> true
        _ -> false
      end)

    case suggestion do
      %{"x" => x, "y" => y, "series" => series}
      when is_binary(x) and is_binary(y) and is_binary(series) ->
        {:ok, %{x: x, y: y, series: series}}

      %{"x" => x, "y" => y} when is_binary(x) and is_binary(y) ->
        {:ok, %{x: x, y: y, series: nil}}

      _ ->
        {:error, :missing_timeseries_suggestion}
    end
  end

  defp parse_timeseries_spec(_), do: {:error, :missing_suggestions}

  defp extract_series_points(results, %{x: x, y: y, series: series_key}) do
    rows =
      results
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_points)

    points =
      Enum.reduce(rows, %{}, fn row, acc ->
        series =
          if is_binary(series_key) do
            Map.get(row, series_key) |> safe_to_string() |> String.trim()
          else
            "series"
          end

        with {:ok, dt} <- parse_datetime(Map.get(row, x)),
             {:ok, value} <- parse_number(Map.get(row, y)) do
          Map.update(acc, series, [{dt, value}], fn existing -> existing ++ [{dt, value}] end)
        else
          _ -> acc
        end
      end)

    series_points =
      points
      |> Enum.sort_by(fn {series, _points} -> series end)
      |> Enum.take(@max_series)

    {:ok, series_points}
  end

  defp parse_number(value) when is_integer(value), do: {:ok, value * 1.0}
  defp parse_number(value) when is_float(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, :empty}

      match?({_, ""}, Float.parse(value)) ->
        {v, ""} = Float.parse(value)
        {:ok, v}

      match?({_, ""}, Integer.parse(value)) ->
        {v, ""} = Integer.parse(value)
        {:ok, v * 1.0}

      true ->
        {:error, :nan}
    end
  end

  defp parse_number(_), do: {:error, :not_numeric}

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :not_datetime}

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp sparkline(points) when is_list(points) do
    values = Enum.map(points, fn {_dt, v} -> v end)

    case {values, Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)} do
      {[], _, _} ->
        ""

      {_values, min_v, max_v} when min_v == max_v ->
        Enum.with_index(values)
        |> Enum.map(fn {_v, idx} ->
          x = idx_to_x(idx, length(values))
          "#{x},60"
        end)
        |> Enum.join(" ")

      {_values, min_v, max_v} ->
        Enum.with_index(values)
        |> Enum.map(fn {v, idx} ->
          x = idx_to_x(idx, length(values))
          y = 110 - round((v - min_v) / (max_v - min_v) * 100)
          "#{x},#{y}"
        end)
        |> Enum.join(" ")
    end
  end

  defp idx_to_x(_idx, 0), do: 0
  defp idx_to_x(0, _len), do: 0

  defp idx_to_x(idx, len) when len > 1 do
    round(idx / (len - 1) * 400)
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
            <div class="text-sm font-semibold">Timeseries</div>
            <div class="text-xs text-base-content/70">
              <span class="font-mono">{@spec[:y]}</span>
              <span class="opacity-70"> over </span>
              <span class="font-mono">{@spec[:x]}</span>
              <span :if={@spec[:series]} class="opacity-70">
                (series: <span class="font-mono">{@spec[:series]}</span>)
              </span>
            </div>
          </div>
        </:header>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <%= for {series, points} <- @series_points do %>
            <div class="rounded-xl border border-base-200 bg-base-100 p-4">
              <div class="text-xs font-semibold mb-2 truncate">{series}</div>
              <svg viewBox="0 0 400 120" class="w-full h-28">
                <polyline
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  class="text-primary"
                  points={sparkline(points)}
                />
              </svg>
            </div>
          <% end %>
        </div>
      </.ui_panel>
    </div>
    """
  end
end
