defmodule ServiceRadarWebNGWeb.InterfaceLive.Index do
  @moduledoc """
  LiveView for listing and searching network interfaces using SRQL.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
  alias ServiceRadarWebNGWeb.Helpers.InterfaceTypes

  @default_limit 20
  @max_limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Interfaces")
     |> assign(:interfaces, [])
     |> assign(:limit, @default_limit)
     |> assign(:total_count, nil)
     |> assign(:current_page, 1)
     |> SRQLPage.init("interfaces", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> SRQLPage.load_list(params, uri, :interfaces,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    query = Map.get(socket.assigns.srql || %{}, :query, "")
    current_page = parse_page_param(params)

    # Get total count for pagination
    total_count = get_total_count(socket.assigns.current_scope, query)

    {:noreply,
     assign(socket,
       total_count: total_count,
       current_page: current_page
     )}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/interfaces")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "interfaces")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/interfaces")}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <!-- Header -->
        <div class="mb-6">
          <h1 class="text-2xl font-semibold text-base-content">Interfaces</h1>
          <p class="text-sm text-base-content/60">
            Search and browse network interfaces across all devices
          </p>
        </div>
        
    <!-- Quick Filters -->
        <div class="mb-4 flex flex-wrap items-center gap-2">
          <span class="text-xs font-medium text-base-content/60 mr-1">Quick filters:</span>
          <.link
            navigate={~p"/interfaces?q=in:interfaces oper_status:1 latest:true"}
            class={"btn btn-xs #{if has_filter?(@srql, "oper_status", "1"), do: "btn-success", else: "btn-ghost"}"}
          >
            <.icon name="hero-arrow-up-circle" class="size-3" /> Up
          </.link>
          <.link
            navigate={~p"/interfaces?q=in:interfaces oper_status:2 latest:true"}
            class={"btn btn-xs #{if has_filter?(@srql, "oper_status", "2"), do: "btn-error", else: "btn-ghost"}"}
          >
            <.icon name="hero-arrow-down-circle" class="size-3" /> Down
          </.link>
          <.link
            navigate={~p"/interfaces?q=in:interfaces favorited:true latest:true"}
            class={"btn btn-xs #{if has_filter?(@srql, "favorited", "true"), do: "btn-warning", else: "btn-ghost"}"}
          >
            <.icon name="hero-star" class="size-3" /> Favorited
          </.link>
          <.link
            navigate={~p"/interfaces?q=in:interfaces metrics_enabled:true latest:true"}
            class={"btn btn-xs #{if has_filter?(@srql, "metrics_enabled", "true"), do: "btn-info", else: "btn-ghost"}"}
          >
            <.icon name="hero-chart-bar" class="size-3" /> Metrics Enabled
          </.link>
          <.link
            :if={has_any_filter?(@srql)}
            navigate={~p"/interfaces"}
            class="btn btn-xs btn-ghost"
          >
            <.icon name="hero-x-mark" class="size-3" /> Clear
          </.link>
        </div>

        <.ui_panel>
          <div class="overflow-x-auto">
            <table class="table table-sm table-zebra w-full">
              <thead>
                <tr>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Device</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Interface</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">
                    MAC Address
                  </th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">
                    IP Addresses
                  </th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Type</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Speed</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Status</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Last Seen</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@interfaces == []}>
                  <td colspan="8" class="py-8 text-center text-sm text-base-content/60">
                    No interfaces found. Try adjusting your search criteria.
                  </td>
                </tr>

                <%= for row <- Enum.filter(@interfaces, &is_map/1) do %>
                  <% device_id = Map.get(row, "device_id") %>
                  <% interface_uid = Map.get(row, "interface_uid") %>
                  <tr class="hover:bg-base-200/40">
                    <td class="text-sm max-w-[12rem] truncate">
                      <.link
                        :if={is_binary(device_id)}
                        navigate={~p"/devices/#{device_id}"}
                        class="link link-hover truncate"
                        title={device_id}
                      >
                        {Map.get(row, "device_ip") || device_id}
                      </.link>
                      <span :if={not is_binary(device_id)} class="text-base-content/40">
                        —
                      </span>
                    </td>
                    <td class="text-sm max-w-[14rem] truncate">
                      <div class="flex items-center gap-2">
                        <.icon
                          :if={Map.get(row, "favorited")}
                          name="hero-star-solid"
                          class="size-3 text-warning"
                        />
                        <.link
                          :if={is_binary(device_id) and is_binary(interface_uid)}
                          navigate={~p"/devices/#{device_id}/interfaces/#{interface_uid}"}
                          class="link link-hover truncate"
                          title={interface_uid}
                        >
                          {interface_name(row)}
                        </.link>
                        <span :if={not (is_binary(device_id) and is_binary(interface_uid))}>
                          {interface_name(row)}
                        </span>
                      </div>
                    </td>
                    <td class="font-mono text-xs">
                      {Map.get(row, "if_phys_address") || Map.get(row, "mac") || "—"}
                    </td>
                    <td class="font-mono text-xs max-w-[10rem] truncate" title={format_ip_list(row)}>
                      {format_ip_list(row) || "—"}
                    </td>
                    <td class="text-xs" title={Map.get(row, "if_type_name")}>
                      {InterfaceTypes.humanize(Map.get(row, "if_type_name")) || "—"}
                    </td>
                    <td class="text-xs">
                      {format_speed(row) || "—"}
                    </td>
                    <td class="text-xs">
                      <.interface_status_badge
                        oper_status={Map.get(row, "if_oper_status")}
                        admin_status={Map.get(row, "if_admin_status")}
                      />
                    </td>
                    <td class="font-mono text-xs">
                      <.srql_cell col="timestamp" value={Map.get(row, "timestamp")} />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-4 pt-4 border-t border-base-200">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              base_path="/interfaces"
              query={Map.get(@srql, :query, "")}
              limit={@limit}
              result_count={length(@interfaces)}
              total_count={@total_count}
              current_page={@current_page}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

  attr :oper_status, :any, required: true
  attr :admin_status, :any, required: true

  defp interface_status_badge(assigns) do
    ~H"""
    <div class="flex gap-1">
      <span class={[
        "badge badge-xs gap-1",
        oper_status_class(@oper_status)
      ]}>
        <.icon name={oper_status_icon(@oper_status)} class="size-3" />
        {oper_status_text(@oper_status)}
      </span>
      <span
        :if={@admin_status && @admin_status != 1}
        class={[
          "badge badge-xs badge-outline gap-1",
          admin_status_class(@admin_status)
        ]}
        title={"Admin: #{admin_status_text(@admin_status)}"}
      >
        {admin_status_text(@admin_status)}
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp get_total_count(scope, query) do
    srql = srql_module()

    # Build a count query based on the current SRQL query
    count_query =
      if query == "" or query == nil do
        "in:interfaces latest:true stats:count() as total"
      else
        # Strip any existing limit/sort and add stats
        base =
          query
          |> String.replace(~r/\blimit:\d+/, "")
          |> String.replace(~r/\bsort:\S+/, "")
          |> String.trim()

        # Ensure latest:true is present for accurate counts
        base =
          if String.contains?(base, "latest:") do
            base
          else
            base <> " latest:true"
          end

        base <> " stats:count() as total"
      end

    case srql.query(count_query, %{scope: scope}) do
      {:ok, %{"results" => [%{"total" => total} | _]}} when is_integer(total) ->
        total

      _ ->
        nil
    end
  end

  defp parse_page_param(params) do
    case Map.get(params, "page") do
      nil -> 1
      page when is_binary(page) -> String.to_integer(page)
      page when is_integer(page) -> page
    end
  rescue
    _ -> 1
  end

  defp interface_name(iface) do
    Map.get(iface, "if_name") ||
      Map.get(iface, "if_descr") ||
      Map.get(iface, "if_alias") ||
      Map.get(iface, "interface_uid") ||
      "Unknown"
  end

  defp format_ip_list(iface) do
    case Map.get(iface, "ip_addresses", []) do
      list when is_list(list) and list != [] -> Enum.join(list, ", ")
      _ -> nil
    end
  end

  defp format_speed(iface) do
    bps = Map.get(iface, "speed_bps") || Map.get(iface, "if_speed")

    cond do
      is_nil(bps) -> nil
      bps >= 1_000_000_000_000 -> "#{Float.round(bps / 1_000_000_000_000 * 1.0, 1)} Tbps"
      bps >= 1_000_000_000 -> "#{Float.round(bps / 1_000_000_000 * 1.0, 1)} Gbps"
      bps >= 1_000_000 -> "#{Float.round(bps / 1_000_000 * 1.0, 1)} Mbps"
      bps >= 1_000 -> "#{Float.round(bps / 1_000 * 1.0, 1)} Kbps"
      true -> "#{bps} bps"
    end
  end

  # Status styling functions
  defp oper_status_class(1), do: "badge-success"
  defp oper_status_class(2), do: "badge-error"
  defp oper_status_class(3), do: "badge-warning"
  defp oper_status_class(_), do: "badge-ghost"

  defp oper_status_icon(1), do: "hero-arrow-up-circle"
  defp oper_status_icon(2), do: "hero-arrow-down-circle"
  defp oper_status_icon(3), do: "hero-beaker"
  defp oper_status_icon(_), do: "hero-question-mark-circle"

  defp oper_status_text(1), do: "Up"
  defp oper_status_text(2), do: "Down"
  defp oper_status_text(3), do: "Testing"
  defp oper_status_text(_), do: "Unknown"

  defp admin_status_class(1), do: "border-success text-success"
  defp admin_status_class(2), do: "border-warning text-warning"
  defp admin_status_class(3), do: "border-info text-info"
  defp admin_status_class(_), do: "border-base-content/30 text-base-content/50"

  defp admin_status_text(1), do: "Enabled"
  defp admin_status_text(2), do: "Disabled"
  defp admin_status_text(3), do: "Testing"
  defp admin_status_text(_), do: "Unknown"

  defp has_filter?(srql, field, value) do
    query = Map.get(srql || %{}, :query, "")
    String.contains?(query, "#{field}:#{value}")
  end

  defp has_any_filter?(srql) do
    query = Map.get(srql || %{}, :query, "")

    query != "" and query != "in:interfaces" and
      not (query |> String.trim() |> String.ends_with?("in:interfaces"))
  end
end
