defmodule ServiceRadarWebNGWeb.DeviceLive.DevicePropertiesComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  attr(:row, :map, required: true)

  def device_properties_card(assigns) do
    row = assigns.row || %{}

    keys =
      row
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    # Exclude metadata, fields already shown in the header card, and the
    # virtual agent-linkage keys injected by DeviceStateData.tag_agent_device/2
    excluded = [
      "metadata",
      "hostname",
      "ip",
      "gateway_id",
      "last_seen",
      "last_seen_time",
      "first_seen",
      "first_seen_time",
      "os_info",
      "version_info",
      "device_id",
      "agent_device",
      "agent_labels"
    ]

    keys = Enum.reject(keys, &(&1 in excluded))

    # Order remaining keys nicely
    preferred = [
      "uid",
      "agent_id",
      "device_type",
      "service_type",
      "service_status",
      "is_available",
      "last_heartbeat"
    ]

    {preferred_keys, other_keys} =
      Enum.split_with(keys, fn k -> k in preferred end)

    ordered_keys =
      preferred
      |> Enum.filter(&(&1 in preferred_keys))
      |> Kernel.++(Enum.sort(other_keys))

    # Only show if there are properties to display
    assigns =
      assigns
      |> assign(:ordered_keys, ordered_keys)
      |> assign(:row, row)
      |> assign(:has_properties, ordered_keys != [])

    ~H"""
    <div :if={@has_properties} class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between">
        <span class="text-sm font-semibold">Device Properties</span>
        <span class="text-xs text-sr-muted">{length(@ordered_keys)} fields</span>
      </div>

      <div class="p-4">
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-1.5 text-sm">
          <%= for key <- @ordered_keys do %>
            <div class="flex items-baseline gap-2 min-w-0 py-0.5">
              <span class="text-sr-muted shrink-0 text-xs">{format_label(key)}:</span>
              <span
                class="font-mono text-xs truncate"
                title={format_prop_value(Map.get(@row, key))}
              >
                {format_prop_value(Map.get(@row, key))}
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp format_label(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_label(key), do: to_string(key)

  defp format_prop_value(nil), do: "—"
  defp format_prop_value(""), do: "—"
  defp format_prop_value(true), do: "Yes"
  defp format_prop_value(false), do: "No"
  defp format_prop_value(value) when is_binary(value), do: String.slice(value, 0, 100)
  defp format_prop_value(value) when is_number(value), do: to_string(value)

  defp format_prop_value(value) when is_list(value) or is_map(value) do
    "#{map_size_or_length(value)} items"
  end

  defp format_prop_value(value), do: value |> inspect() |> String.slice(0, 50)

  defp map_size_or_length(value) when is_map(value), do: map_size(value)
  defp map_size_or_length(value) when is_list(value), do: length(value)
  defp map_size_or_length(_), do: 0
end
