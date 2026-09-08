defmodule ServiceRadarWebNGWeb.DeviceLive.Wifi do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_entity "wifi_sites"
  @default_limit 50
  @max_limit 200
  @page_path "/devices/wifi"
  @wifi_entities ~w(
    wifi_sites
    wifi_site_snapshots
    wifi_aps
    wifi_controllers
    wifi_radius_groups
    wifi_fleet_history
    wifi_site_references
  )

  @columns %{
    "wifi_sites" => [
      {"site_code", "Site"},
      {"site_name", "Name"},
      {"region", "Region"},
      {"site_type", "Type"},
      {"ap_count", "APs"},
      {"up_count", "Up"},
      {"down_count", "Down"},
      {"wlc_count", "Controllers"},
      {"collection_timestamp", "Collected"}
    ],
    "wifi_site_snapshots" => [
      {"collection_timestamp", "Collected"},
      {"site_code", "Site"},
      {"site_name", "Name"},
      {"ap_count", "APs"},
      {"up_count", "Up"},
      {"down_count", "Down"},
      {"wlc_count", "Controllers"},
      {"server_group", "Server Group"}
    ],
    "wifi_aps" => [
      {"hostname", "Hostname"},
      {"site_code", "Site"},
      {"status", "Status"},
      {"ip", "IP"},
      {"mac", "MAC"},
      {"serial", "Serial"},
      {"model", "Model"},
      {"collection_timestamp", "Collected"}
    ],
    "wifi_controllers" => [
      {"hostname", "Hostname"},
      {"site_code", "Site"},
      {"status", "Status"},
      {"ip", "IP"},
      {"model", "Model"},
      {"aos_version", "AOS"},
      {"base_mac", "Base MAC"},
      {"collection_timestamp", "Collected"}
    ],
    "wifi_radius_groups" => [
      {"site_code", "Site"},
      {"controller_alias", "Controller"},
      {"aaa_profile", "AAA Profile"},
      {"server_group", "Server Group"},
      {"cluster", "Cluster"},
      {"status", "Status"},
      {"collection_timestamp", "Collected"}
    ],
    "wifi_fleet_history" => [
      {"build_date", "Build Date"},
      {"ap_total", "APs"},
      {"count_2xx", "2xx"},
      {"count_3xx", "3xx"},
      {"count_5xx", "5xx"},
      {"count_6xx", "6xx"},
      {"pct_6xx", "6xx %"},
      {"pct_legacy", "Legacy %"},
      {"site_count", "Sites"}
    ],
    "wifi_site_references" => [
      {"site_code", "Site"},
      {"site_name", "Name"},
      {"site_type", "Type"},
      {"region", "Region"},
      {"latitude", "Latitude"},
      {"longitude", "Longitude"},
      {"updated_at", "Updated"}
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "WiFi Inventory")
     |> assign(:current_path, @page_path)
     |> assign(:page_path, @page_path)
     |> assign(:active_entity, @default_entity)
     |> assign(:limit, @default_limit)
     |> assign(:wifi_rows, [])
     |> assign(:columns, columns_for(@default_entity))
     |> assign(:column_count, length(columns_for(@default_entity)))
     |> assign(:entity_tabs, entity_tabs())
     |> stream(:wifi_rows, [], dom_id: &row_dom_id/1)
     |> SRQLPage.init(@default_entity, default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {entity, params} = wifi_entity_and_params(params)

    socket =
      socket
      |> assign(:active_entity, entity)
      |> assign(:columns, columns_for(entity))
      |> assign(:column_count, length(columns_for(entity)))
      |> assign(:srql, Map.put(socket.assigns.srql, :entity, entity))
      |> SRQLPage.load_list(params, uri, :wifi_rows, default_limit: @default_limit, max_limit: @max_limit)

    {:noreply, stream(socket, :wifi_rows, socket.assigns.wifi_rows, reset: true, dom_id: &row_dom_id/1)}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: @page_path)}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: @page_path)}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: socket.assigns.active_entity)}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: @page_path)}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: socket.assigns.active_entity)}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: socket.assigns.active_entity)}
  end

  def handle_event("srql_paginate", params, socket) do
    socket =
      SRQLPage.handle_event(socket, "srql_paginate", params,
        list_assign_key: :wifi_rows,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    {:noreply, stream(socket, :wifi_rows, socket.assigns.wifi_rows, reset: true, dom_id: &row_dom_id/1)}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={@page_title}
      srql={@srql}
    >
      <div class="mx-auto flex w-full max-w-7xl flex-col gap-4 px-4 py-6 sm:px-6 lg:px-8">
        <section class="flex flex-col gap-3 border-b border-sr-line pb-5 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-sm font-medium text-sr-brand">Devices</p>
            <h1 class="mt-1 text-2xl font-semibold tracking-normal">WiFi Inventory</h1>
            <p class="mt-2 max-w-3xl text-sm text-sr-ink/65">
              Site, access point, controller, RADIUS, and fleet records from imported WiFi map data.
            </p>
          </div>
          <.ui_button navigate={~p"/devices"} size="sm" variant="ghost">
            <.icon name="hero-server-stack" class="size-4" /> Device List
          </.ui_button>
        </section>

        <nav class="flex flex-wrap gap-2" aria-label="WiFi inventory views">
          <.ui_button
            :for={tab <- @entity_tabs}
            patch={~p"/devices/wifi?#{%{q: tab.query}}"}
            size="sm"
            variant={if(tab.id == @active_entity, do: "primary", else: "ghost")}
            active={tab.id == @active_entity}
          >
            {tab.label}
          </.ui_button>
        </nav>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">{Catalog.entity(@active_entity).label}</div>
              <div class="text-xs text-sr-muted">{Map.get(@srql, :query, "")}</div>
            </div>
          </:header>

          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "sm", zebra: true)}>
              <thead>
                <tr>
                  <th :for={{_field, label} <- @columns}>{label}</th>
                </tr>
              </thead>
              <tbody id="wifi-rows" phx-update="stream">
                <tr :if={length(@wifi_rows) == 0} id="wifi-rows-empty">
                  <td colspan={@column_count} class="py-8 text-center text-sr-muted">
                    No WiFi inventory rows found.
                  </td>
                </tr>
                <%= for {dom_id, row} <- @streams.wifi_rows do %>
                  <tr id={dom_id}>
                    <td :for={{field, _label} <- @columns} class="whitespace-nowrap">
                      <% timestamp = timestamp_value(field, Map.get(row, field)) %>
                      <%= if timestamp do %>
                        <.user_time
                          id={"#{dom_id}-#{field}"}
                          value={timestamp}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                        />
                      <% else %>
                        {format_value(Map.get(row, field))}
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-4 border-t border-sr-line pt-4">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              limit={@limit}
              current_page={Map.get(assigns, :pagination_page, 1)}
              result_count={length(@wifi_rows)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  defp wifi_entity_and_params(params) do
    query = Map.get(params, "q")
    entity = entity_from_query(query)

    if entity in @wifi_entities do
      {entity, params}
    else
      {@default_entity, Map.put(params, "q", default_query(@default_entity))}
    end
  end

  defp entity_from_query(query) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)in:(\S+)/, query) do
      [_, entity] -> entity
      _ -> @default_entity
    end
  end

  defp entity_from_query(_query), do: @default_entity

  defp entity_tabs do
    Enum.map(@wifi_entities, fn entity ->
      %{id: entity, label: Catalog.entity(entity).label, query: default_query(entity)}
    end)
  end

  defp default_query(entity) do
    entity
    |> Builder.default_state(@default_limit)
    |> Builder.build()
  end

  defp columns_for(entity), do: Map.fetch!(@columns, entity)

  defp row_dom_id(row) do
    id =
      Map.get(row, "id") ||
        Map.get(row, "device_uid") ||
        [Map.get(row, "source_id"), Map.get(row, "site_code"), Map.get(row, "collection_timestamp")]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")

    suffix =
      case id do
        "" -> :erlang.phash2(row)
        nil -> :erlang.phash2(row)
        value -> value
      end

    "wifi-row-#{suffix}"
  end

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(value) when is_list(value), do: Enum.map_join(value, ", ", &format_value/1)
  defp format_value(value) when is_map(value), do: inspect(value)
  defp format_value(value), do: to_string(value)

  defp timestamp_value(field, value) when field in ["collection_timestamp", "updated_at", "build_date"] do
    case value do
      %DateTime{} = datetime ->
        datetime

      %NaiveDateTime{} = naive ->
        DateTime.from_naive!(naive, "Etc/UTC")

      value when is_binary(value) ->
        with {:error, _} <- DateTime.from_iso8601(value),
             {:ok, naive} <- NaiveDateTime.from_iso8601(value) do
          DateTime.from_naive!(naive, "Etc/UTC")
        else
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp timestamp_value(_field, _value), do: nil
end
