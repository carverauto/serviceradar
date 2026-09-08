defmodule ServiceRadarWebNGWeb.GatewayLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 20
  @max_limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Gateways")
     |> assign(:gateways, [])
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("gateways", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply, SRQLPage.load_list(socket, params, uri, :gateways, default_limit: @default_limit, max_limit: @max_limit)}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/gateways")}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: "/gateways")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "gateways")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/gateways")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "gateways")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "gateways")}
  end

  def handle_event("srql_paginate", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_paginate", params,
       list_assign_key: :gateways,
       default_limit: @default_limit,
       max_limit: @max_limit
     )}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}

    assigns =
      assigns
      |> assign(:pagination, pagination)
      |> assign(:timezone, user_timezone(assigns[:current_scope]))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.ui_panel>
          <.gateways_table id="gateways" gateways={@gateways} timezone={@timezone} />

          <div class="mt-4 pt-4 border-t border-sr-line">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              limit={@limit}
              current_page={Map.get(assigns, :pagination_page, 1)}
              result_count={length(@gateways)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :gateways, :list, default: []
  attr :timezone, :string, required: true

  defp gateways_table(assigns) do
    ~H"""
    <div class="sr-ui-table-shell">
      <table id={@id} class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-48">
              Gateway ID
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-24">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Address
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Last Seen
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@gateways == []}>
            <td colspan="4" class="text-sm text-sr-muted py-8 text-center">
              No gateways found.
            </td>
          </tr>

          <%= for {gateway, idx} <- Enum.with_index(@gateways) do %>
            <% {timestamp, timestamp_fallback} = gateway_timestamp(gateway) %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-sr-subtle/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/gateways/#{gateway_id(gateway)}")}
            >
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[12rem]"
                title={gateway_id(gateway)}
              >
                {gateway_id(gateway)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.status_badge active={Map.get(gateway, "is_active")} />
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[10rem]"
                title={gateway_address(gateway)}
              >
                {gateway_address(gateway)}
              </td>
              <td class="whitespace-nowrap text-xs font-mono">
                <.user_time
                  id={"gateway-#{gateway_id(gateway)}-last-seen"}
                  value={timestamp}
                  timezone={@timezone}
                  style={:full}
                  fallback={timestamp_fallback}
                />
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :active, :any, default: nil

  defp status_badge(assigns) do
    {label, variant} =
      case assigns.active do
        true -> {"Active", "success"}
        false -> {"Inactive", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp gateway_id(gateway) do
    Map.get(gateway, "gateway_id") || Map.get(gateway, "id") || "unknown"
  end

  defp gateway_address(gateway) do
    Map.get(gateway, "address") ||
      Map.get(gateway, "gateway_address") ||
      Map.get(gateway, "host") ||
      Map.get(gateway, "hostname") ||
      Map.get(gateway, "ip") ||
      Map.get(gateway, "ip_address") ||
      "—"
  end

  defp gateway_timestamp(gateway) do
    ts = Map.get(gateway, "last_seen") || Map.get(gateway, "updated_at")

    case parse_timestamp(ts) do
      {:ok, dt} -> {dt, timestamp_fallback(ts)}
      _ -> {nil, timestamp_fallback(ts)}
    end
  end

  defp timestamp_fallback(value) when is_binary(value) and value != "", do: value
  defp timestamp_fallback(_value), do: "—"

  defp parse_timestamp(nil), do: :error
  defp parse_timestamp(""), do: :error
  defp parse_timestamp(%DateTime{} = value), do: {:ok, value}

  defp parse_timestamp(%NaiveDateTime{} = value) do
    {:ok, DateTime.from_naive!(value, "Etc/UTC")}
  end

  defp parse_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp parse_timestamp(_), do: :error

  defp user_timezone(%{user: %{timezone: timezone}}) when is_binary(timezone) and timezone != "", do: timezone

  defp user_timezone(_current_scope), do: "Etc/UTC"
end
