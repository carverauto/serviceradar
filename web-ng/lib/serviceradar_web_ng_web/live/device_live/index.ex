defmodule ServiceRadarWebNGWeb.DeviceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 100
  @max_limit 500
  @sparkline_device_cap 200
  @sparkline_points_per_device 20
  @sparkline_bucket "5m"
  @sparkline_window "last_1h"
  @sparkline_threshold_ms 100.0

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Devices")
     |> assign(:devices, [])
     |> assign(:icmp_sparklines, %{})
     |> assign(:icmp_error, nil)
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("devices", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> SRQLPage.load_list(params, uri, :devices,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    {icmp_sparklines, icmp_error} = load_icmp_sparklines(srql_module(), socket.assigns.devices)

    {:noreply, assign(socket, icmp_sparklines: icmp_sparklines, icmp_error: icmp_error)}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/devices")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "devices")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "devices")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "devices")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Devices
          <:subtitle>Showing up to {@limit} devices.</:subtitle>
          <:actions>
            <.link class="btn btn-ghost btn-sm" patch={~p"/devices?limit=#{@limit}"}>
              Reset
            </.link>
          </:actions>
        </.header>

        <.ui_panel>
          <:header>
            <div class="min-w-0">
              <div class="text-sm font-semibold">Devices</div>
              <div class="text-xs text-base-content/70">
                Click a device to view details.
              </div>
            </div>
            <div :if={is_binary(@icmp_error)} class="text-xs text-warning">
              ICMP sparkline: {@icmp_error}
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-sm table-zebra w-full">
              <thead>
                <tr>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Device</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Hostname</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">IP</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Health</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Poller</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Last Seen</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@devices == []}>
                  <td colspan="6" class="py-8 text-center text-sm text-base-content/60">
                    No devices found.
                  </td>
                </tr>

                <%= for row <- Enum.filter(@devices, &is_map/1) do %>
                  <% device_id = Map.get(row, "device_id") || Map.get(row, "id") %>
                  <% icmp =
                    if is_binary(device_id), do: Map.get(@icmp_sparklines, device_id), else: nil %>
                  <tr class="hover:bg-base-200/40">
                    <td class="font-mono text-xs">
                      <.link
                        :if={is_binary(device_id)}
                        navigate={~p"/devices/#{device_id}"}
                        class="link link-hover"
                      >
                        {device_id}
                      </.link>
                      <span :if={not is_binary(device_id)} class="text-base-content/70">—</span>
                    </td>
                    <td class="text-sm max-w-[18rem] truncate">{Map.get(row, "hostname") || "—"}</td>
                    <td class="font-mono text-xs">{Map.get(row, "ip") || "—"}</td>
                    <td class="text-xs">
                      <div class="flex items-center gap-2">
                        <.availability_badge available={Map.get(row, "is_available")} />
                        <.icmp_sparkline :if={is_map(icmp)} spark={icmp} />
                      </div>
                    </td>
                    <td class="font-mono text-xs">{Map.get(row, "poller_id") || "—"}</td>
                    <td class="font-mono text-xs">
                      <.srql_cell col="last_seen" value={Map.get(row, "last_seen")} />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :available, :any, default: nil

  def availability_badge(assigns) do
    {label, variant} =
      case assigns.available do
        true -> {"Online", "success"}
        false -> {"Offline", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  attr :spark, :map, required: true

  def icmp_sparkline(assigns) do
    assigns =
      assigns
      |> assign(:points, Map.get(assigns.spark, :points, []))
      |> assign(:latest_ms, Map.get(assigns.spark, :latest_ms, 0.0))
      |> assign(:tone, Map.get(assigns.spark, :tone, "success"))
      |> assign(:title, Map.get(assigns.spark, :title))
      |> assign(:polyline, sparkline_points(Map.get(assigns.spark, :points, [])))

    ~H"""
    <div class="flex items-center gap-2">
      <div class="h-8 w-20 rounded-md border border-base-200 bg-base-100 px-1 py-0.5">
        <svg viewBox="0 0 400 120" class={["w-full h-full", tone_text(@tone)]}>
          <title>{@title || "ICMP latency"}</title>
          <polyline
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            points={@polyline}
          />
        </svg>
      </div>
      <div class={["font-mono text-[11px]", tone_text(@tone)]}>
        {format_ms(@latest_ms)}
      </div>
    </div>
    """
  end

  defp tone_text("error"), do: "text-error"
  defp tone_text("warning"), do: "text-warning"
  defp tone_text("success"), do: "text-success"
  defp tone_text(_), do: "text-base-content/70"

  defp format_ms(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1) <> "ms"
  end

  defp format_ms(value) when is_integer(value), do: Integer.to_string(value) <> "ms"
  defp format_ms(_), do: "—"

  defp sparkline_points(values) when is_list(values) do
    values = Enum.filter(values, &is_number/1)

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

  defp load_icmp_sparklines(srql_module, devices) do
    device_ids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "device_id") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@sparkline_device_cap)

    if device_ids == [] do
      {%{}, nil}
    else
      query =
        [
          "in:timeseries_metrics",
          "metric_type:icmp",
          "device_id:(#{Enum.map_join(device_ids, ",", &escape_list_value/1)})",
          "time:#{@sparkline_window}",
          "bucket:#{@sparkline_bucket}",
          "agg:avg",
          "series:device_id",
          "limit:#{min(length(device_ids) * @sparkline_points_per_device, 4000)}"
        ]
        |> Enum.join(" ")

      case srql_module.query(query) do
        {:ok, %{"results" => rows}} when is_list(rows) ->
          {build_icmp_sparklines(rows), nil}

        {:ok, other} ->
          {%{}, "unexpected SRQL response: #{inspect(other)}"}

        {:error, reason} ->
          {%{}, format_error(reason)}
      end
    end
  end

  defp escape_list_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> then(&"\"#{&1}\"")
  end

  defp build_icmp_sparklines(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn row, acc ->
      device_id = Map.get(row, "series") || Map.get(row, "device_id")
      timestamp = Map.get(row, "timestamp")
      value_ms = latency_ms(Map.get(row, "value"))

      if is_binary(device_id) and value_ms > 0 do
        Map.update(
          acc,
          device_id,
          [%{ts: timestamp, v: value_ms}],
          fn existing -> existing ++ [%{ts: timestamp, v: value_ms}] end
        )
      else
        acc
      end
    end)
    |> Map.new(fn {device_id, points} ->
      points =
        points
        |> Enum.sort_by(fn p -> p.ts end)
        |> Enum.take(-@sparkline_points_per_device)

      values = Enum.map(points, & &1.v)
      latest_ms = List.last(values) || 0.0

      tone =
        cond do
          latest_ms >= @sparkline_threshold_ms -> "warning"
          latest_ms > 0 -> "success"
          true -> "ghost"
        end

      title =
        case List.last(points) do
          %{ts: ts} when is_binary(ts) -> "ICMP #{format_ms(latest_ms)} · #{ts}"
          _ -> "ICMP #{format_ms(latest_ms)}"
        end

      {device_id, %{points: values, latest_ms: latest_ms, tone: tone, title: title}}
    end)
  end

  defp build_icmp_sparklines(_), do: %{}

  defp latency_ms(value) when is_float(value) or is_integer(value) do
    raw = if is_integer(value), do: value * 1.0, else: value
    if raw > 1_000_000.0, do: raw / 1_000_000.0, else: raw
  end

  defp latency_ms(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> latency_ms(parsed)
      _ -> 0.0
    end
  end

  defp latency_ms(_), do: 0.0

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
