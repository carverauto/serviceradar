defmodule ServiceRadarWebNGWeb.ServiceLive.Show.HistoryTable do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.ServiceLive.Service
  alias ServiceRadarWebNGWeb.ServiceLive.Show.Query

  attr :services, :list, default: []
  attr :page, :integer, default: 1
  attr :per_page, :integer, default: 20

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
    <div class="overflow-x-auto">
      <table class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-20">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Message
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@page_services == []}>
            <td colspan="3" class="text-sm text-base-content/60 py-6 text-center">
              No service checks found.
            </td>
          </tr>

          <%= for {service, index} <- Enum.with_index(@page_services) do %>
            <% path = Service.details_path(service) %>
            <tr
              id={"service-history-row-#{index}"}
              class="hover:bg-base-200/40 cursor-pointer"
              phx-click={JS.navigate(path)}
            >
              <td class="whitespace-nowrap text-xs font-mono">
                {format_timestamp(service)}
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

      <div :if={@total_pages > 1} class="flex items-center justify-between mt-4 px-2">
        <div class="text-xs text-base-content/60">
          Showing {(@current_page - 1) * @per_page + 1}-{min(@current_page * @per_page, @total)} of {@total}
        </div>
        <div class="join">
          <button
            class="join-item btn btn-xs"
            disabled={@current_page <= 1}
            phx-click="history_page"
            phx-value-page={@current_page - 1}
          >
            Prev
          </button>
          <span class="join-item btn btn-xs btn-disabled">
            {@current_page} / {@total_pages}
          </span>
          <button
            class="join-item btn btn-xs"
            disabled={@current_page >= @total_pages}
            phx-click="history_page"
            phx-value-page={@current_page + 1}
          >
            Next
          </button>
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

  defp format_timestamp(service) do
    timestamp = Map.get(service, "timestamp")

    case Query.parse_datetime(timestamp) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
      _ -> timestamp || "—"
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
