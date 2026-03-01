defmodule ServiceRadarWebNGWeb.FlowStatComponents do
  @moduledoc """
  Reusable Phoenix function components for displaying flow/traffic statistics.

  All components are pure — they accept data via assigns and emit events via
  callback attrs. No internal SRQL queries or data fetching. This makes them
  embeddable in any LiveView context: the flows dashboard, device details
  flows tab, topology drill-downs, alert context panels, etc.

  ## Usage

      import ServiceRadarWebNGWeb.FlowStatComponents

      <.stat_card title="Total Bandwidth" value={@bandwidth_bps} unit="bps" trend={12.5} />
      <.top_n_table rows={@top_talkers} on_row_click={&handle_drill_down/1} />
      <.traffic_sparkline id="bw-spark" data_json={@sparkline_json} />
      <.protocol_breakdown id="proto-donut" data_json={@proto_json} />
      <.bandwidth_gauge id="bw-gauge" current_bps={@current} capacity_bps={@capacity} />
  """

  use Phoenix.Component
  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]

  # ---------------------------------------------------------------------------
  # Unit formatting helpers
  # ---------------------------------------------------------------------------

  @si_prefixes [
    {1.0e15, "P"},
    {1.0e12, "T"},
    {1.0e9, "G"},
    {1.0e6, "M"},
    {1.0e3, "K"}
  ]

  @doc """
  Formats a raw numeric value with SI prefix abbreviation.

  ## Options
    * `:unit` — suffix label, e.g. `"bps"`, `"Bps"`, `"pps"` (default `""`)
    * `:decimals` — decimal places (default `1`)

  ## Examples

      iex> format_si(1_234_567_890, unit: "bps")
      "1.2 Gbps"

      iex> format_si(42_300, unit: "pps")
      "42.3 Kpps"

      iex> format_si(850, unit: "bps")
      "850 bps"
  """
  @spec format_si(number(), keyword()) :: String.t()
  def format_si(value, opts \\ []) when is_number(value) do
    unit = Keyword.get(opts, :unit, "")
    decimals = Keyword.get(opts, :decimals, 1)
    abs_val = abs(value)

    {scaled, prefix} =
      Enum.find_value(@si_prefixes, {value, ""}, fn {threshold, prefix} ->
        if abs_val >= threshold, do: {value / threshold, prefix}
      end)

    formatted =
      if prefix == "" and scaled == trunc(scaled) do
        Integer.to_string(trunc(scaled))
      else
        :erlang.float_to_binary(scaled * 1.0, decimals: decimals)
      end

    suffix = if unit == "", do: prefix, else: "#{prefix}#{unit}"
    String.trim("#{formatted} #{suffix}")
  end

  @doc """
  Converts a raw byte count to the selected unit mode.

  Modes: `"bps"` (bits/sec), `"Bps"` (bytes/sec), `"pps"` (packets/sec — pass-through).
  """
  @spec convert_bytes(number(), String.t()) :: number()
  def convert_bytes(bytes, "bps"), do: bytes * 8
  def convert_bytes(bytes, _mode), do: bytes

  # ---------------------------------------------------------------------------
  # stat_card — single KPI with optional trend and sparkline slot
  # ---------------------------------------------------------------------------

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, default: ""
  attr :trend, :float, default: nil, doc: "Percentage change, e.g. 12.5 or -3.2"
  attr :loading, :boolean, default: false
  attr :class, :any, default: nil

  slot :sparkline, doc: "Optional inline sparkline rendered below the value"

  def stat_card(assigns) do
    formatted =
      if is_number(assigns.value) do
        format_si(assigns.value, unit: assigns.unit)
      else
        to_string(assigns.value)
      end

    assigns = assign(assigns, :formatted_value, formatted)

    ~H"""
    <div class={[
      "rounded-xl border border-base-200 bg-base-100 shadow-sm p-4 flex flex-col gap-1",
      @class
    ]}>
      <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
        {@title}
      </div>

      <div :if={@loading} class="flex items-center gap-2 h-8">
        <span class="loading loading-spinner loading-sm"></span>
      </div>

      <div :if={not @loading} class="flex items-baseline gap-2">
        <span class="text-2xl font-bold text-base-content tabular-nums">
          {@formatted_value}
        </span>
        <.trend_badge :if={@trend != nil} value={@trend} />
      </div>

      <div :if={@sparkline != [] and not @loading} class="mt-1 h-8">
        {render_slot(@sparkline)}
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # top_n_table — ranked table with click-to-drill-down
  # ---------------------------------------------------------------------------

  attr :rows, :list, required: true, doc: "List of maps, each row rendered in order"

  attr :columns, :list,
    required: true,
    doc: "List of `%{key: atom, label: string}` or `%{key: atom, label: string, format: fun}`"

  attr :on_row_click, :any, default: nil, doc: "JS command or callback, receives row data"
  attr :title, :string, default: nil
  attr :loading, :boolean, default: false
  attr :empty_message, :string, default: "No data"
  attr :class, :any, default: nil

  def top_n_table(assigns) do
    ~H"""
    <div class={["rounded-xl border border-base-200 bg-base-100 shadow-sm overflow-hidden", @class]}>
      <div :if={@title} class="px-4 py-3 bg-base-200/40 border-b border-base-200">
        <h3 class="text-sm font-semibold text-base-content">{@title}</h3>
      </div>

      <div :if={@loading} class="flex items-center justify-center py-8">
        <span class="loading loading-spinner loading-md"></span>
      </div>

      <div :if={not @loading and @rows == []} class="px-4 py-8 text-center text-base-content/50 text-sm">
        {@empty_message}
      </div>

      <table :if={not @loading and @rows != []} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="w-8 text-center">#</th>
            <th :for={col <- @columns} class="text-xs uppercase tracking-wide">
              {col_label(col)}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={{row, idx} <- Enum.with_index(@rows, 1)}
            class={[@on_row_click && "cursor-pointer hover:bg-base-200/60"]}
            phx-click={@on_row_click}
            phx-value-row-idx={idx - 1}
          >
            <td class="text-center text-base-content/50 font-mono text-xs">{idx}</td>
            <td :for={col <- @columns} class="text-sm">
              {format_cell(col, row)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # traffic_sparkline — lightweight inline area chart via JS hook
  # ---------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :data_json, :string, required: true, doc: "JSON array of {t: epoch_ms, v: number}"
  attr :color, :string, default: "oklch(var(--p))"
  attr :height, :integer, default: 32
  attr :class, :any, default: nil

  def traffic_sparkline(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="FlowSparkline"
      data-points={@data_json}
      data-color={@color}
      class={["w-full", @class]}
      style={"height: #{@height}px"}
    >
      <canvas class="w-full h-full"></canvas>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # protocol_breakdown — donut/pie chart via JS hook
  # ---------------------------------------------------------------------------

  attr :id, :string, required: true

  attr :data_json, :string,
    required: true,
    doc: "JSON array of {label: string, value: number, color?: string}"

  attr :height, :integer, default: 200
  attr :class, :any, default: nil

  def protocol_breakdown(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="FlowDonut"
      data-slices={@data_json}
      class={["rounded-xl border border-base-200 bg-base-100 shadow-sm p-4", @class]}
    >
      <div class="flex items-center justify-center" style={"height: #{@height}px"}>
        <canvas class="max-w-full max-h-full"></canvas>
      </div>
      <div data-legend class="mt-2 flex flex-wrap gap-2 text-xs"></div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # bandwidth_gauge — arc gauge showing percent of capacity
  # ---------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :current_bps, :float, required: true
  attr :capacity_bps, :float, required: true
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def bandwidth_gauge(assigns) do
    pct =
      if assigns.capacity_bps > 0,
        do: Float.round(assigns.current_bps / assigns.capacity_bps * 100, 1),
        else: 0.0

    severity =
      cond do
        pct >= 90 -> "error"
        pct >= 70 -> "warning"
        true -> "success"
      end

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:severity, severity)
      |> assign(:formatted_current, format_si(assigns.current_bps, unit: "bps"))
      |> assign(:formatted_capacity, format_si(assigns.capacity_bps, unit: "bps"))

    ~H"""
    <div
      id={@id}
      class={[
        "rounded-xl border border-base-200 bg-base-100 shadow-sm p-4 flex flex-col items-center gap-2",
        @class
      ]}
    >
      <div class={["radial-progress", "text-#{@severity}"]} style={"--value:#{@pct}; --size:5rem; --thickness:6px;"} role="progressbar">
        <span class="text-sm font-bold">{@pct}%</span>
      </div>
      <div :if={@label} class="text-xs font-medium text-base-content/70">{@label}</div>
      <div class="text-xs text-base-content/50">
        {@formatted_current} / {@formatted_capacity}
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # trend_badge — small up/down indicator for stat_card
  # ---------------------------------------------------------------------------

  attr :value, :float, required: true

  defp trend_badge(assigns) do
    {icon_name, color_class} =
      cond do
        assigns.value > 0 -> {"hero-arrow-trending-up-mini", "text-success"}
        assigns.value < 0 -> {"hero-arrow-trending-down-mini", "text-error"}
        true -> {"hero-minus-mini", "text-base-content/50"}
      end

    assigns =
      assigns
      |> assign(:icon_name, icon_name)
      |> assign(:color_class, color_class)

    ~H"""
    <span class={["inline-flex items-center gap-0.5 text-xs font-medium", @color_class]}>
      <.icon name={@icon_name} class="w-3.5 h-3.5" />
      {abs(@value) |> Float.round(1)}%
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp col_label(%{label: label}), do: label
  defp col_label(%{key: key}), do: key |> to_string() |> String.replace("_", " ")

  defp format_cell(%{format: fmt}, row) when is_function(fmt, 1), do: fmt.(row)

  defp format_cell(%{key: key}, row) do
    val = Map.get(row, key) || Map.get(row, to_string(key))

    case val do
      n when is_integer(n) -> delimit_integer(n)
      n when is_float(n) -> :erlang.float_to_binary(n, decimals: 1)
      nil -> "-"
      other -> to_string(other)
    end
  end

  defp delimit_integer(n) when n >= 1000 do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}/, "\\0,")
    |> String.reverse()
    |> String.trim_leading(",")
  end

  defp delimit_integer(n), do: Integer.to_string(n)
end
