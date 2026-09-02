defmodule ServiceRadarWebNGWeb.DeviceLive.BumblebeeComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  attr(:postures, :list, default: [])
  attr(:findings, :list, default: [])
  attr(:error, :string, default: nil)
  attr(:has_exposure, :boolean, default: false)
  attr(:timezone, :string, default: "Etc/UTC")

  def bumblebee_section(assigns) do
    assigns =
      assigns
      |> assign(:latest_posture, List.first(assigns.postures || []))
      |> assign(:finding_count, length(assigns.findings || []))

    ~H"""
    <section
      :if={@has_exposure or is_binary(@error)}
      class="rounded-lg border border-sr-line bg-sr-surface shadow-sm"
    >
      <div class="flex flex-col gap-3 border-b border-sr-line px-4 py-3 md:flex-row md:items-center md:justify-between">
        <div>
          <h2 class="text-sm font-semibold text-sr-ink">Bumblebee Exposure</h2>
          <p class="text-xs text-sr-muted">
            {@finding_count} active finding rows | {length(@postures || [])} scanner postures
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.ui_badge size="sm" variant={state_badge_variant(field(@latest_posture, :state))}>
            {empty_dash(field(@latest_posture, :state))}
          </.ui_badge>
          <.ui_badge
            size="sm"
            variant={severity_badge_variant(field(@latest_posture, :highest_severity))}
          >
            {severity_label(field(@latest_posture, :highest_severity))}
          </.ui_badge>
        </div>
      </div>

      <div :if={is_binary(@error)} class="px-4 py-3 text-sm text-error">
        {@error}
      </div>

      <div class="grid gap-4 p-4 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <div class="space-y-4">
          <div class="grid grid-cols-2 gap-3">
            <.summary_stat label="Risk Score" value={field(@latest_posture, :risk_score) || 0} />
            <.summary_stat
              label="Active Findings"
              value={field(@latest_posture, :active_finding_count) || @finding_count}
            />
            <.summary_stat label="Coverage" value={field(@latest_posture, :coverage_state)} />
            <.summary_stat label="Last Scan">
              <.user_time
                id={"device-bumblebee-#{time_key(field(@latest_posture, :run_id) || "latest")}-last-scan-at"}
                value={field(@latest_posture, :last_scan_at)}
                timezone={@timezone}
                style={:compact}
              />
            </.summary_stat>
          </div>

          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "sm")}>
              <tbody>
                <.posture_row label="Agent" value={field(@latest_posture, :agent_id)} mono />
                <.posture_row label="Run" value={field(@latest_posture, :run_id)} mono />
                <.posture_row
                  label="Catalog"
                  value={field(@latest_posture, :catalog_snapshot_ref)}
                  mono
                />
                <.posture_row label="Scanner" value={field(@latest_posture, :scanner_version)} />
                <.posture_row label="Roots Scanned" value={root_summary(@latest_posture)} />
                <.posture_row
                  label="Root Covered"
                  value={bool_display(field(@latest_posture, :root_covered))}
                />
              </tbody>
            </table>
          </div>

          <div :if={skipped_roots(@latest_posture) != []} class="rounded border border-sr-line p-3">
            <h3 class="mb-2 text-xs font-semibold uppercase text-sr-muted">Skipped Roots</h3>
            <div class="space-y-1">
              <div :for={root <- skipped_roots(@latest_posture)} class="text-xs">
                <span class="font-mono">{field(root, :path)}</span>
                <span class="text-sr-muted">{field(root, :reason)}</span>
              </div>
            </div>
          </div>
        </div>

        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr>
                <th>Finding</th>
                <th>Package</th>
                <th>Severity</th>
                <th>Last Seen</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@findings == []}>
                <td colspan="4" class="py-6 text-center text-sm text-sr-muted">
                  No active Bumblebee findings.
                </td>
              </tr>
              <tr :for={{finding, index} <- Enum.with_index(@findings)}>
                <td class="max-w-56 truncate font-mono text-xs">
                  {field(finding, :catalog_id) || field(finding, :finding_id)}
                </td>
                <td>
                  <div class="font-medium">{empty_dash(field(finding, :package_name))}</div>
                  <div class="font-mono text-xs text-sr-muted">
                    {empty_dash(field(finding, :package_version))}
                  </div>
                </td>
                <td>
                  <.ui_badge size="sm" variant={severity_badge_variant(field(finding, :severity))}>
                    {severity_label(field(finding, :severity))}
                  </.ui_badge>
                </td>
                <td class="font-mono text-xs">
                  <.user_time
                    id={"device-bumblebee-finding-#{finding_time_key(finding, index)}-last-seen-at"}
                    value={field(finding, :last_seen_at)}
                    timezone={@timezone}
                    style={:compact}
                  />
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
  attr(:value, :any, default: nil)
  slot(:inner_block)

  defp summary_stat(assigns) do
    ~H"""
    <div class="rounded border border-sr-line bg-sr-subtle/30 px-3 py-2">
      <div class="text-[0.65rem] font-semibold uppercase text-sr-muted">{@label}</div>
      <div class="mt-1 truncate text-sm font-semibold">
        <%= if @inner_block != [] do %>
          {render_slot(@inner_block)}
        <% else %>
          {empty_dash(@value)}
        <% end %>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:mono, :boolean, default: false)

  defp posture_row(assigns) do
    ~H"""
    <tr>
      <th class="w-32 text-xs text-sr-muted">{@label}</th>
      <td class={["text-xs", @mono && "font-mono"]}>{empty_dash(@value)}</td>
    </tr>
    """
  end

  defp field(nil, _field), do: nil
  defp field(%{} = row, field), do: Map.get(row, field) || Map.get(row, to_string(field))
  defp field(row, field) when is_struct(row), do: Map.get(row, field)
  defp field(_row, _field), do: nil

  defp root_summary(nil), do: nil

  defp root_summary(posture) do
    scanned = field(posture, :scanned_root_count) || 0
    attempted = field(posture, :attempted_root_count) || 0
    skipped = field(posture, :skipped_root_count) || 0
    "#{scanned}/#{attempted} scanned, #{skipped} skipped"
  end

  defp skipped_roots(nil), do: []
  defp skipped_roots(posture), do: field(posture, :skipped_roots) || []

  defp bool_display(true), do: "yes"
  defp bool_display(false), do: "no"
  defp bool_display(_), do: "-"

  defp empty_dash(nil), do: "-"
  defp empty_dash(""), do: "-"
  defp empty_dash(value), do: to_string(value)

  defp finding_time_key(finding, index) do
    [
      field(finding, :catalog_id),
      field(finding, :finding_id),
      field(finding, :id),
      field(finding, :uid)
    ]
    |> Enum.find_value(&optional_time_key/1)
    |> Kernel.||(Integer.to_string(index))
  end

  defp optional_time_key(value) when value in [nil, ""], do: nil

  defp optional_time_key(value) do
    case time_key(value) do
      "" -> nil
      key -> key
    end
  end

  defp time_key(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp state_badge_variant("scanned"), do: "success"
  defp state_badge_variant("scan_failed"), do: "error"
  defp state_badge_variant("not_scanned"), do: "ghost"
  defp state_badge_variant(_), do: "outline"

  defp severity_badge_variant(value) do
    case value |> to_string() |> String.downcase() do
      "critical" -> "error"
      "high" -> "warning"
      "medium" -> "info"
      "low" -> "success"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "Unknown"
  defp severity_label(""), do: "Unknown"
  defp severity_label(value), do: value |> to_string() |> String.capitalize()
end
