defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  attr(:scan, :any, default: nil)
  attr(:scans, :list, default: [])
  attr(:packages, :list, default: [])
  attr(:artifacts, :list, default: [])
  attr(:error, :string, default: nil)
  attr(:has_inventory, :boolean, default: false)
  attr(:device_row, :map, default: nil)

  def endpoint_inventory_section(assigns) do
    assigns =
      assigns
      |> assign(:package_count, length(assigns.packages || []))
      |> assign(:scan_count, length(assigns.scans || []))
      |> assign(:risk_score, device_value(assigns.device_row, "risk_score"))
      |> assign(:risk_level, device_value(assigns.device_row, "risk_level"))

    ~H"""
    <section
      :if={@has_inventory or is_binary(@error)}
      class="rounded-lg border border-base-300 bg-base-100 shadow-sm"
    >
      <div class="flex flex-col gap-3 border-b border-base-300 px-4 py-3 md:flex-row md:items-center md:justify-between">
        <div>
          <h2 class="text-sm font-semibold text-base-content">Endpoint Software</h2>
          <p class="text-xs text-base-content/60">
            {@package_count} current package rows | {@scan_count} scans
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.scan_status_badge scan={@scan} />
          <.risk_badge risk_level={@risk_level} risk_score={@risk_score} />
        </div>
      </div>

      <div :if={is_binary(@error)} class="px-4 py-3 text-sm text-error">
        {@error}
      </div>

      <div class="grid gap-4 p-4 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
        <div class="space-y-4">
          <div class="grid grid-cols-2 gap-3">
            <.summary_stat label="Packages" value={inventory_count(@scan, @package_count)} />
            <.summary_stat label="Scans" value={@scan_count} />
            <.summary_stat label="Risk Score" value={risk_score_display(@risk_score)} />
            <.summary_stat label="Risk Level" value={risk_level_display(@risk_level)} />
          </div>

          <div class="overflow-hidden rounded border border-base-300">
            <table class="table table-sm">
              <tbody>
                <.scan_row label="State" value={field(@scan, :state)} />
                <.scan_row label="Coverage" value={field(@scan, :coverage_state)} />
                <.scan_row label="Agent" value={field(@scan, :agent_id)} mono />
                <.scan_row label="Last Scan" value={format_timestamp(field(@scan, :last_scan_at))} />
                <.scan_row
                  label="Last Changed"
                  value={format_timestamp(field(@scan, :last_changed_scan_at))}
                />
                <.scan_row label="Upload Reason" value={field(@scan, :upload_reason)} />
                <.scan_row
                  label="Unchanged"
                  value={field(@scan, :unchanged_scan_count) || 0}
                />
                <.scan_row
                  label="Package Hash"
                  value={truncate_hash(field(@scan, :package_set_hash))}
                  mono
                />
                <.scan_row
                  :if={field(@scan, :package_set_hash_mismatch)}
                  label="Hash Check"
                  value="Mismatch"
                />
              </tbody>
            </table>
          </div>

          <div :if={@artifacts != []} class="overflow-hidden rounded border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Artifact</th>
                  <th>Size</th>
                  <th>Uploaded</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={artifact <- @artifacts}>
                  <td class="max-w-64 truncate font-mono text-xs">{field(artifact, :object_key)}</td>
                  <td class="font-mono text-xs">{format_bytes(field(artifact, :size_bytes))}</td>
                  <td class="font-mono text-xs">{format_timestamp(field(artifact, :uploaded_at))}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="overflow-hidden rounded border border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Package</th>
                <th>Version</th>
                <th>Manager</th>
                <th>Coordinate</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@packages == []}>
                <td colspan="4" class="py-6 text-center text-sm text-base-content/60">
                  No current package rows.
                </td>
              </tr>
              <tr :for={package <- @packages}>
                <td class="font-medium">{field(package, :name)}</td>
                <td class="font-mono text-xs">{empty_dash(field(package, :version))}</td>
                <td>
                  <span class="badge badge-outline badge-sm">{field(package, :package_manager)}</span>
                </td>
                <td class="max-w-80 truncate font-mono text-xs">
                  {field(package, :purl_canonical) || field(package, :purl) ||
                    List.first(field(package, :cpes) || []) || "-"}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp summary_stat(assigns) do
    ~H"""
    <div class="rounded border border-base-300 bg-base-200/30 px-3 py-2">
      <div class="text-[0.65rem] font-semibold uppercase text-base-content/50">{@label}</div>
      <div class="mt-1 truncate text-sm font-semibold">{empty_dash(@value)}</div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:mono, :boolean, default: false)

  defp scan_row(assigns) do
    ~H"""
    <tr>
      <th class="w-32 text-xs text-base-content/60">{@label}</th>
      <td class={["text-xs", @mono && "font-mono"]}>{empty_dash(@value)}</td>
    </tr>
    """
  end

  attr(:scan, :any, default: nil)

  defp scan_status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", scan_status_class(field(@scan, :state))]}>
      {empty_dash(field(@scan, :state))}
    </span>
    """
  end

  attr(:risk_level, :any, default: nil)
  attr(:risk_score, :any, default: nil)

  defp risk_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", risk_class(@risk_level, @risk_score)]}>
      {risk_level_display(@risk_level)} {risk_score_suffix(@risk_score)}
    </span>
    """
  end

  defp field(nil, _field), do: nil
  defp field(%{} = row, field), do: Map.get(row, field) || Map.get(row, to_string(field))
  defp field(_row, _field), do: nil

  defp device_value(nil, _key), do: nil

  defp device_value(%{} = row, "risk_score"), do: Map.get(row, "risk_score") || Map.get(row, :risk_score)

  defp device_value(%{} = row, "risk_level"), do: Map.get(row, "risk_level") || Map.get(row, :risk_level)

  defp device_value(%{} = row, key), do: Map.get(row, key)
  defp device_value(_row, _key), do: nil

  defp inventory_count(scan, fallback), do: field(scan, :package_count) || fallback || 0

  defp risk_score_display(nil), do: "-"
  defp risk_score_display(value), do: to_string(value)

  defp risk_level_display(nil), do: "Unknown"
  defp risk_level_display(""), do: "Unknown"
  defp risk_level_display(value), do: to_string(value)

  defp risk_score_suffix(nil), do: ""
  defp risk_score_suffix(value), do: "(#{value})"

  defp risk_class("Critical", _score), do: "badge-error"
  defp risk_class("High", _score), do: "badge-warning"
  defp risk_class("Medium", _score), do: "badge-info"
  defp risk_class("Low", _score), do: "badge-success"
  defp risk_class(_level, score) when is_integer(score) and score >= 80, do: "badge-error"
  defp risk_class(_level, score) when is_integer(score) and score >= 50, do: "badge-warning"
  defp risk_class(_level, _score), do: "badge-ghost"

  defp scan_status_class("scanned"), do: "badge-success"
  defp scan_status_class("upload_deferred"), do: "badge-warning"
  defp scan_status_class("scan_failed"), do: "badge-error"
  defp scan_status_class(_state), do: "badge-ghost"

  defp truncate_hash(nil), do: nil

  defp truncate_hash(value) when is_binary(value) and byte_size(value) > 18, do: String.slice(value, 0, 18) <> "..."

  defp truncate_hash(value), do: value

  defp empty_dash(nil), do: "-"
  defp empty_dash(""), do: "-"
  defp empty_dash(value), do: value

  defp format_timestamp(nil), do: "-"

  defp format_timestamp(%DateTime{} = value) do
    value
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_timestamp(value), do: to_string(value)

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_bytes), do: "-"
end
