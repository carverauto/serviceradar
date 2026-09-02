defmodule ServiceRadarWebNGWeb.DeviceLive.LogComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  # ---------------------------------------------------------------------------
  # Logs Tab Content
  # ---------------------------------------------------------------------------

  attr(:logs, :list, required: true)
  attr(:error, :string, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:pagination, :map, default: %{})
  attr(:pagination_page, :integer, default: 1)
  attr(:device_uid, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def device_logs_tab_content(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-clipboard-document-list" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Device Logs</span>
          <span class="text-xs text-sr-muted">({length(@logs)} rows)</span>
        </div>
        <.link
          navigate={~p"/observability/logs?#{%{"q" => @query}}"}
          class="text-xs text-sr-brand hover:underline"
        >
          Open full logs view
        </.link>
      </div>

      <div class="p-4">
        <div :if={is_binary(@error)} class="mb-3 text-xs text-error">{@error}</div>

        <%= if @loading do %>
          <div class="flex items-center gap-2 text-sm text-sr-muted">
            <.ui_spinner size="sm" /> Loading device logs...
          </div>
        <% else %>
          <%= if @logs == [] and is_nil(@error) do %>
            <div class="text-sm text-sr-muted">No logs found for this device.</div>
          <% else %>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
                <thead>
                  <tr>
                    <th class="w-40">Time</th>
                    <th class="w-24">Level</th>
                    <th class="w-44">Service</th>
                    <th>Message</th>
                    <th class="w-20 text-right"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{log, index} <- Enum.with_index(@logs)}>
                    <td class="whitespace-nowrap text-xs font-mono">
                      <.user_time
                        id={"device-log-#{log_time_key(log, index)}-timestamp"}
                        value={log_timestamp(log)}
                        timezone={@timezone}
                        style={:compact}
                      />
                    </td>
                    <td class="whitespace-nowrap text-xs">
                      <.ui_badge variant={log_severity_variant(log)} size="xs">
                        {log_severity_label(log)}
                      </.ui_badge>
                    </td>
                    <td
                      class="whitespace-nowrap text-xs truncate max-w-[14rem]"
                      title={log_service(log)}
                    >
                      {log_service(log)}
                    </td>
                    <td class="text-xs truncate max-w-[42rem]" title={log_message(log)}>
                      {log_message(log)}
                    </td>
                    <td class="text-right">
                      <.ui_button
                        :if={log_id(log) != "unknown"}
                        navigate={~p"/logs/#{log_id(log)}"}
                        size="xs"
                        variant="ghost"
                      >
                        Details
                      </.ui_button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="pt-3 border-t border-sr-line mt-3">
              <.ui_pagination
                prev_cursor={Map.get(@pagination, "prev_cursor")}
                next_cursor={Map.get(@pagination, "next_cursor")}
                limit={@limit}
                current_page={@pagination_page}
                result_count={length(@logs)}
              />
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp log_timestamp(log) when is_map(log) do
    Map.get(log, "observed_timestamp") || Map.get(log, "timestamp") || Map.get(log, "time")
  end

  defp log_timestamp(_log), do: nil

  defp log_id(log) when is_map(log) do
    case Map.get(log, "id") do
      nil -> "unknown"
      id when is_binary(id) -> id
      id -> to_string(id)
    end
  end

  defp log_id(_log), do: "unknown"

  defp log_severity_variant(log) when is_map(log) do
    case log |> Map.get("severity_text") |> normalize_log_severity() do
      value when value in ["critical", "fatal", "error"] -> "error"
      value when value in ["high", "warn", "warning"] -> "warning"
      value when value in ["medium", "info"] -> "info"
      value when value in ["low", "debug", "trace", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp log_severity_variant(_log), do: "ghost"

  defp log_severity_label(log) when is_map(log) do
    case Map.get(log, "severity_text") do
      nil -> "—"
      "" -> "—"
      value when is_binary(value) -> value |> String.upcase() |> String.slice(0, 5)
      value -> value |> to_string() |> String.upcase() |> String.slice(0, 5)
    end
  end

  defp log_severity_label(_log), do: "—"

  defp normalize_log_severity(nil), do: ""

  defp normalize_log_severity(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  defp normalize_log_severity(value), do: value |> to_string() |> normalize_log_severity()

  defp log_service(log) when is_map(log) do
    log
    |> first_present(["service_name", "source", "scope_name"])
    |> present_or_dash()
  end

  defp log_service(_log), do: "—"

  defp log_message(log) when is_map(log) do
    log
    |> first_present(["body", "message", "short_message"])
    |> present_or_dash()
    |> String.slice(0, 300)
  end

  defp log_message(_log), do: "—"

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp present_or_dash(nil), do: "—"
  defp present_or_dash(""), do: "—"
  defp present_or_dash(value) when is_binary(value), do: value
  defp present_or_dash(value), do: to_string(value)

  defp log_time_key(log, index) do
    [Map.get(log, "id"), Map.get(log, :id)]
    |> Enum.find_value(&log_id_fragment/1)
    |> Kernel.||(Integer.to_string(index))
  end

  defp log_id_fragment(value) when value in [nil, ""], do: nil

  defp log_id_fragment(value) do
    case value |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-") |> String.trim("-") do
      "" -> nil
      fragment -> fragment
    end
  end
end
