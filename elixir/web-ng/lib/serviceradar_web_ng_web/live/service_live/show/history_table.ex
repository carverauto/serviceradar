defmodule ServiceRadarWebNGWeb.ServiceLive.Show.HistoryTable do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.ServiceLive.Service
  alias ServiceRadarWebNGWeb.ServiceLive.Show.Query

  attr :services, :list, default: []
  attr :page, :integer, default: 1
  attr :per_page, :integer, default: 20
  attr :timezone, :string, required: true

  def render(assigns) do
    total = length(assigns.services)
    total_pages = max(1, ceil(total / assigns.per_page))
    page = min(assigns.page, total_pages)
    start_index = (page - 1) * assigns.per_page

    assigns =
      assigns
      |> assign(:page_services, Enum.slice(assigns.services, start_index, assigns.per_page))
      |> assign(:total, total)
      |> assign(:total_pages, total_pages)
      |> assign(:current_page, page)

    ~H"""
    <div class="sr-ui-table-shell">
      <table class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-20">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Message
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@page_services == []}>
            <td colspan="3" class="text-sm text-sr-muted py-6 text-center">
              No service checks found.
            </td>
          </tr>

          <%= for service <- @page_services do %>
            <% path = Service.details_path(service) %>
            <% entry_id = history_entry_id(service) %>
            <tr
              id={"service-history-row-#{entry_id}"}
              class="hover:bg-sr-subtle/40 cursor-pointer"
              phx-click={JS.navigate(path)}
            >
              <td class="whitespace-nowrap text-xs font-mono">
                <.user_time
                  id={"service-history-#{entry_id}-timestamp"}
                  value={history_timestamp(service)}
                  timezone={@timezone}
                  style={:full}
                  fallback={Service.timestamp_fallback(service)}
                />
              </td>
              <td class="whitespace-nowrap text-xs">
                <.status_badge available={Map.get(service, "available")} />
              </td>
              <td class="text-xs truncate max-w-[32rem]" title={history_message(service)}>
                {history_message(service)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <div :if={@total_pages > 1} class="mt-4 flex items-center justify-between px-2">
        <div class="text-xs text-sr-muted">
          Showing {(@current_page - 1) * @per_page + 1}-{min(@current_page * @per_page, @total)} of {@total}
        </div>
        <div class="flex items-center gap-1">
          <.ui_button
            type="button"
            size="xs"
            variant="outline"
            disabled={@current_page <= 1}
            phx-click="history_page"
            phx-value-page={@current_page - 1}
          >
            Prev
          </.ui_button>
          <span class="inline-flex min-h-7 items-center px-2 text-xs text-sr-muted">
            {@current_page} / {@total_pages}
          </span>
          <.ui_button
            type="button"
            size="xs"
            variant="outline"
            disabled={@current_page >= @total_pages}
            phx-click="history_page"
            phx-value-page={@current_page + 1}
          >
            Next
          </.ui_button>
        </div>
      </div>
    </div>
    """
  end

  attr :available, :any, default: nil

  defp status_badge(assigns) do
    {label, variant} =
      case Service.normalize_available(assigns.available) do
        true -> {"OK", "success"}
        false -> {"FAIL", "error"}
        _ -> {"—", "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp history_entry_id(service) do
    case first_history_identity(service) do
      nil -> Integer.to_string(:erlang.phash2(service))
      "" -> Integer.to_string(:erlang.phash2(service))
      id -> dom_id_fragment(id, service)
    end
  end

  defp first_history_identity(service) do
    Enum.find(
      [
        Map.get(service, "id"),
        Map.get(service, :id),
        Map.get(service, "service_id"),
        Map.get(service, :service_id),
        Map.get(service, "uid"),
        Map.get(service, :uid)
      ],
      fn value -> not blank_identity?(value) end
    )
  end

  defp blank_identity?(nil), do: true
  defp blank_identity?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_identity?(_value), do: false

  defp dom_id_fragment(value, service) do
    case value |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-") do
      "" -> Integer.to_string(:erlang.phash2(service))
      fragment -> fragment
    end
  end

  defp history_timestamp(service) do
    case Query.parse_datetime(Map.get(service, "timestamp")) do
      {:ok, datetime} -> datetime
      _ -> Service.timestamp(service)
    end
  end

  defp history_message(service) do
    details = Service.parse_details(service)
    message = Service.summary(service, details) || Map.get(service, "message")
    normalize_history_message(message) || "—"
  end

  defp normalize_history_message(nil), do: nil

  defp normalize_history_message(message) when is_binary(message) do
    trimmed = String.trim(message)

    cond do
      trimmed == "" ->
        nil

      String.starts_with?(trimmed, "{") ->
        case Jason.decode(trimmed) do
          {:ok, %{"summary" => summary}} when is_binary(summary) and summary != "" -> summary
          {:ok, %{"message" => inner}} when is_binary(inner) and inner != "" -> inner
          _ -> message
        end

      true ->
        message
    end
  end

  defp normalize_history_message(message), do: to_string(message)
end
