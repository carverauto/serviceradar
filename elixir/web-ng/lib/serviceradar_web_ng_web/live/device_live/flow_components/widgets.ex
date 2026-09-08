defmodule ServiceRadarWebNGWeb.DeviceLive.FlowComponents.Widgets do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.FlowComponents.Formatters

  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:items_json, :string, required: true)
  attr(:filter_field, :string, required: true)

  def top_n_widget(assigns) do
    items =
      case Jason.decode(assigns.items_json) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    max_value = items |> Enum.map(&Map.get(&1, "value", 0)) |> Enum.max(fn -> 1 end)

    items =
      Enum.map(items, fn item ->
        pct = min(100, round(Map.get(item, "value", 0) / max(1, max_value) * 100))
        Map.put(item, "pct", pct)
      end)

    assigns = assign(assigns, items: items)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
      <div class="flex items-center gap-2 mb-3">
        <.icon name={@icon} class="size-4 text-sr-brand" />
        <span class="text-sm font-semibold">{@title}</span>
        <span class="text-xs text-sr-muted">(last 24h)</span>
      </div>
      <div class="space-y-1.5">
        <button
          :for={item <- @items}
          type="button"
          class="w-full text-left group"
          phx-click="topn_filter"
          phx-value-field={@filter_field}
          phx-value-value={item["filter_value"] || item["label"]}
        >
          <div class="flex items-center justify-between text-xs">
            <span class="font-mono truncate max-w-[60%] group-hover:text-sr-brand transition-colors">
              {item["label"]}
            </span>
            <span class="text-sr-muted">{format_bytes(item["value"])}</span>
          </div>
          <div class="w-full bg-sr-subtle rounded-full h-1 mt-0.5">
            <div
              class="bg-sr-brand/40 group-hover:bg-sr-brand/60 h-1 rounded-full transition-colors"
              style={"width: #{item["pct"]}%"}
            >
            </div>
          </div>
        </button>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:field, :string, required: true)
  attr(:items, :list, required: true)
  attr(:active_facets, :map, required: true)

  def facet_group(assigns) do
    active_value = Map.get(assigns.active_facets, assigns.field)
    assigns = assign(assigns, :active_value, active_value)

    ~H"""
    <div class="flex items-center gap-1.5">
      <span class="text-xs text-sr-muted font-medium">{@label}:</span>
      <.ui_button
        :for={item <- @items}
        type="button"
        size="xs"
        variant={if(@active_value == item.label, do: "primary", else: "ghost")}
        phx-click="facet_toggle"
        phx-value-field={@field}
        phx-value-value={Map.get(item, :filter_value) || item.label}
      >
        {item.label}
      </.ui_button>
    </div>
    """
  end

  attr(:value, :any, required: true)
  attr(:max, :any, required: true)
  attr(:label, :string, required: true)

  def data_bar(assigns) do
    case_result =
      case assigns.value do
        n when is_number(n) -> n
        s when is_binary(s) -> flow_stat_number(%{"n" => s}, "n")
        _ -> 0
      end

    value = max(case_result, 0)

    case_result =
      case assigns.max do
        n when is_number(n) -> n
        s when is_binary(s) -> flow_stat_number(%{"n" => s}, "n")
        _ -> 0
      end

    maxv = max(case_result, 0)

    pct = if maxv > 0, do: min(100, round(value / maxv * 100)), else: 0
    assigns = assign(assigns, value: value, max: maxv, pct: pct)

    ~H"""
    <div class="relative inline-flex items-center justify-end w-full min-w-[60px]">
      <div
        class="absolute inset-y-0 right-0 bg-sr-brand/10 rounded-sm"
        style={"width: #{@pct}%"}
      >
      </div>
      <span class="relative z-10">{@label}</span>
    </div>
    """
  end

  attr(:flow, :map, required: true)

  def flow_interface_path(assigns) do
    conn_info = get_in(assigns.flow, ["ocsf_payload", "connection_info"]) || %{}
    in_snmp = conn_info["input_snmp"]
    out_snmp = conn_info["output_snmp"]

    in_if = Map.get(assigns.flow, "in_if_name") || snmp_id_label(in_snmp)
    out_if = Map.get(assigns.flow, "out_if_name") || snmp_id_label(out_snmp)
    assigns = assign(assigns, in_if: in_if, out_if: out_if)

    ~H"""
    <span :if={@in_if || @out_if} class="inline-flex items-center gap-1 text-sr-muted">
      <span :if={@in_if} class="truncate max-w-[70px]" title={@in_if}>{@in_if}</span>
      <span :if={@in_if && @out_if} class="text-sr-muted">&rarr;</span>
      <span :if={@out_if} class="truncate max-w-[70px]" title={@out_if}>{@out_if}</span>
    </span>
    <span :if={!@in_if && !@out_if} class="text-sr-ink/30">—</span>
    """
  end
end
