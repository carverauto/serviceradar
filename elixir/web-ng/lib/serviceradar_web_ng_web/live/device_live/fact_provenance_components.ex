defmodule ServiceRadarWebNGWeb.DeviceLive.FactProvenanceComponents do
  @moduledoc """
  Surfaces a device's externally supplied facts and their provenance as a
  first-class section on device details.

  Facts are written through the device facts API, which stores each value at
  its own metadata key and stamps who wrote it and when under
  `metadata["__fact_provenance"][key]` (see `MergeDeviceFacts`). Operators
  triage on that provenance, so it renders open rather than buried in the
  collapsed All Metadata card. A device without provenance renders nothing.
  """

  use ServiceRadarWebNGWeb, :html

  @provenance_key "__fact_provenance"

  attr(:device_row, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def fact_provenance_section(assigns) do
    assigns = assign(assigns, :facts, provenance_facts(assigns.device_row))

    ~H"""
    <div
      :if={@facts != []}
      id="device-fact-provenance"
      class="rounded-xl border border-sr-line bg-sr-surface"
    >
      <div class="flex items-center gap-2 border-b border-sr-line px-4 py-3">
        <.icon name="hero-finger-print" class="size-4 shrink-0 text-secondary" />
        <span class="text-sm font-semibold">Fact Provenance</span>
        <span class="rounded-full bg-secondary/10 px-2 py-0.5 text-[11px] font-semibold text-secondary">
          {length(@facts)} {if length(@facts) == 1, do: "fact", else: "facts"}
        </span>
      </div>

      <div class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b border-sr-line text-left text-xs text-sr-muted">
              <th class="px-4 py-2 font-medium">Fact</th>
              <th class="px-4 py-2 font-medium">Value</th>
              <th class="px-4 py-2 font-medium">Source</th>
              <th class="px-4 py-2 font-medium">Updated</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-sr-line/60">
            <tr :for={fact <- @facts} id={"device-fact-provenance-#{fact.key}"}>
              <td class="px-4 py-2 font-mono text-xs text-sr-ink break-all">{fact.key}</td>
              <td class="px-4 py-2 text-sr-ink break-words">{fact.value}</td>
              <td class="px-4 py-2 text-sr-ink break-words">{fact.source}</td>
              <td class="px-4 py-2 whitespace-nowrap">
                <.user_time
                  id={"device-fact-provenance-#{fact.key}-updated"}
                  value={fact.updated_at}
                  timezone={@timezone}
                  style={:compact}
                  class="font-mono text-xs text-sr-ink"
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp provenance_facts(row) do
    metadata = row_metadata(row)

    case Map.get(metadata, @provenance_key) do
      provenance when is_map(provenance) ->
        provenance
        |> Enum.map(fn {key, entry} -> build_fact(to_string(key), entry, metadata) end)
        |> Enum.sort_by(& &1.key)

      _ ->
        []
    end
  end

  defp build_fact(key, entry, metadata) do
    entry = if is_map(entry), do: entry, else: %{}

    %{
      key: key,
      value: format_value(Map.get(metadata, key)),
      source: format_value(Map.get(entry, "source")),
      updated_at: Map.get(entry, "updated_at")
    }
  end

  defp row_metadata(row) when is_map(row) do
    case Map.get(row, "metadata") || Map.get(row, :metadata) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp row_metadata(_row), do: %{}

  defp format_value(nil), do: "—"

  defp format_value(value) when is_binary(value) do
    if String.trim(value) == "", do: "—", else: value
  end

  defp format_value(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp format_value(value), do: inspect(value)
end
