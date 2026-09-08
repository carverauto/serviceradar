defmodule ServiceRadarWebNGWeb.Flows.AttributedLive do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadarWebNGWeb.NetFlow.EnrichmentExpiry
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Ash.Query
  require Logger

  @refresh_interval_ms 5_000
  @time_window_hours 24
  @default_filter "attributed"
  @filters ~w(attributed unmatched all)
  @default_page_size 50
  @max_page_size 100

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Attributed Flows")
      |> assign(:current_path, "/observability/flows/attributed")
      |> assign(:time_window_hours, @time_window_hours)
      |> assign(:filter, @default_filter)
      |> assign(:page, 1)
      |> assign(:page_size, @default_page_size)
      |> assign(:page_count, 1)
      |> assign(:live?, false)
      |> assign(:summary, empty_summary())
      |> assign(:rows, [])
      |> assign(:rows_by_id, %{})
      |> assign(:selected_flow, nil)
      |> assign(:loading?, connected?(socket))
      |> assign(:load_request, nil)
      |> stream(:attributed_flows, [], dom_id: &flow_dom_id/1)
      |> SRQLPage.init("attributed_flows", default_limit: @default_page_size)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    page = normalize_page(params["page"])

    socket =
      socket
      |> assign(:filter, normalize_filter(params["filter"]))
      |> assign(:page, page)
      |> assign(:page_size, normalize_page_size(params["per_page"]))
      |> assign(:selected_flow, nil)
      |> assign(:live?, Map.get(socket.assigns, :live?, false) and page == 1)
      |> sync_srql(params, uri)
      |> begin_load_flows()

    {:noreply, socket}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/observability/flows/attributed")}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: "/observability/flows/attributed")}
  end

  def handle_event("srql_builder_toggle", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", params, entity: "attributed_flows")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params, entity: "attributed_flows")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "attributed_flows")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "attributed_flows")}
  end

  def handle_event("srql_builder_apply", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", params, entity: "attributed_flows")}
  end

  def handle_event("srql_builder_run", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_run", params, fallback_path: "/observability/flows/attributed")}
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: patch_path(filter, 1, socket.assigns.page_size))}
  end

  def handle_event("goto_page", %{"page" => page}, socket) do
    page = normalize_page(page)

    {:noreply,
     socket
     |> assign(:live?, false)
     |> push_patch(to: patch_path(socket.assigns.filter, page, socket.assigns.page_size))}
  end

  def handle_event("toggle_live", _params, socket) do
    cond do
      socket.assigns.live? ->
        {:noreply, assign(socket, :live?, false)}

      socket.assigns.page > 1 ->
        schedule_refresh()

        {:noreply,
         socket
         |> assign(:live?, true)
         |> push_patch(to: patch_path(socket.assigns.filter, 1, socket.assigns.page_size))}

      true ->
        schedule_refresh()
        {:noreply, assign(socket, :live?, true)}
    end
  end

  def handle_event("open_flow", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_flow, Map.get(socket.assigns.rows_by_id, id))}
  end

  def handle_event("close_flow", _params, socket) do
    {:noreply, assign(socket, :selected_flow, nil)}
  end

  @impl true
  def handle_info(:refresh, %{assigns: %{live?: true}} = socket) do
    schedule_refresh()
    {:noreply, begin_load_flows(socket)}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:attributed_flows_load, request_id}, {:ok, data}, socket) do
    if request_id == socket.assigns.load_request do
      rows_by_id = Map.new(data.rows, &{&1.id, &1})
      selected_flow = refresh_selected_flow(socket.assigns.selected_flow, rows_by_id)

      {:noreply,
       socket
       |> assign(:summary, data.summary)
       |> assign(:page, data.page)
       |> assign(:page_count, data.page_count)
       |> assign(:rows, data.rows)
       |> assign(:rows_by_id, rows_by_id)
       |> assign(:selected_flow, selected_flow)
       |> assign(:loading?, false)
       |> stream(:attributed_flows, data.rows, reset: true, dom_id: &flow_dom_id/1)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:attributed_flows_load, request_id}, {:exit, reason}, socket) do
    Logger.warning("Attributed flow async load failed: #{inspect(reason)}")

    socket =
      if request_id == socket.assigns.load_request do
        assign(socket, :loading?, false)
      else
        socket
      end

    {:noreply, socket}
  end

  defp begin_load_flows(socket) do
    if connected?(socket) do
      request_id = System.unique_integer([:positive])
      scope = socket.assigns.current_scope
      srql_module = srql_module()
      query = socket.assigns.srql.query
      page = socket.assigns.page
      page_size = socket.assigns.page_size
      filter = socket.assigns.filter

      socket
      |> assign(:loading?, true)
      |> assign(:load_request, request_id)
      |> start_async({:attributed_flows_load, request_id}, fn ->
        load_flows_data(srql_module, scope, query, page, page_size, filter)
      end)
    else
      socket
    end
  end

  defp load_flows_data(srql_module, scope, query, page, page_size, filter) do
    summary = fetch_summary(srql_module, scope)
    total_for_filter = summary_count(summary, filter)
    page_count = page_count(total_for_filter, page_size)
    page = min(page, page_count)

    rows =
      srql_module
      |> fetch_flows(scope, query, page, page_size)
      |> enrich_rows_with_rdns(scope)

    %{
      summary: summary,
      page: page,
      page_count: page_count,
      rows: rows
    }
  end

  defp sync_srql(socket, params, uri) do
    query = normalize_query(params["q"], socket.assigns.filter, socket.assigns.page_size)
    page_path = uri |> to_string() |> URI.parse() |> Map.get(:path)

    srql =
      Map.merge(socket.assigns.srql, %{
        enabled: true,
        entity: "attributed_flows",
        page_path: page_path,
        query: query,
        draft: query,
        error: nil,
        loading: false
      })

    assign(socket, :srql, srql)
  end

  defp fetch_summary(srql_module, scope) do
    query =
      ~s|in:attributed_flows time:last_24h stats:"count(*) as total, sum(bytes_total) as total_bytes by attribution_status" sort:total:desc limit:10|

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) ->
        summarize_stat_rows(rows)

      {:ok, _} ->
        empty_summary()

      {:error, reason} ->
        Logger.warning("Attributed flow SRQL summary query failed: #{inspect(reason)}")
        empty_summary()
    end
  rescue
    error ->
      Logger.warning("Attributed flow SRQL summary query raised: #{Exception.message(error)}")
      empty_summary()
  end

  defp summarize_stat_rows(rows) do
    Enum.reduce(rows, empty_summary(), fn row, acc ->
      count = row |> map_value("total") |> parse_int() || 0
      bytes = row |> map_value("total_bytes") |> parse_int() || 0

      acc =
        acc
        |> Map.update!(:total, &(&1 + count))
        |> Map.update!(:bytes, &(&1 + bytes))

      case row |> map_value("attribution_status") |> to_string() |> String.downcase() do
        "attributed" -> Map.update!(acc, :attributed, &(&1 + count))
        "unmatched" -> Map.update!(acc, :unmatched, &(&1 + count))
        _ -> acc
      end
    end)
  end

  defp empty_summary, do: %{total: 0, attributed: 0, unmatched: 0, bytes: 0}

  defp fetch_flows(srql_module, scope, query, page, page_size) do
    fetch_flows_page(srql_module, scope, query, page_size, nil, page)
  rescue
    error ->
      Logger.warning("Attributed flow SRQL rows query raised: #{Exception.message(error)}")
      []
  end

  defp fetch_flows_page(srql_module, scope, query, page_size, cursor, page) when page > 1 do
    case query_flows_page(srql_module, scope, query, page_size, cursor) do
      {:ok, _rows, next_cursor} when is_binary(next_cursor) ->
        fetch_flows_page(srql_module, scope, query, page_size, next_cursor, page - 1)

      _ ->
        []
    end
  end

  defp fetch_flows_page(srql_module, scope, query, page_size, cursor, _page) do
    case query_flows_page(srql_module, scope, query, page_size, cursor) do
      {:ok, rows, _next_cursor} ->
        Enum.map(rows, &row_from_srql/1)

      _ ->
        []
    end
  end

  defp query_flows_page(srql_module, scope, query, page_size, cursor) do
    opts = %{scope: scope, limit: page_size, cursor: cursor}

    case srql_module.query(query, opts) do
      {:ok, %{"results" => rows, "pagination" => pagination}} when is_list(rows) and is_map(pagination) ->
        {:ok, rows, map_value(pagination, "next_cursor")}

      {:ok, %{"results" => rows}} when is_list(rows) ->
        {:ok, rows, nil}

      {:ok, _} ->
        {:ok, [], nil}

      {:error, reason} ->
        Logger.warning("Attributed flow SRQL rows query failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("Attributed flow SRQL rows query raised: #{Exception.message(error)}")
      {:error, error}
  end

  defp enrich_rows_with_rdns(rows, scope) when is_list(rows) do
    rdns_map =
      rows
      |> Enum.flat_map(&[&1.source, &1.destination])
      |> Enum.filter(&present?/1)
      |> Enum.uniq()
      |> rdns_map_for_ips(scope)

    Enum.map(rows, fn row ->
      %{
        row
        | source_hostname: Map.get(rdns_map, row.source),
          destination_hostname: Map.get(rdns_map, row.destination)
      }
    end)
  end

  defp rdns_map_for_ips([], _scope), do: %{}
  defp rdns_map_for_ips(_ips, nil), do: %{}

  defp rdns_map_for_ips(ips, scope) when is_list(ips) do
    now = DateTime.utc_now()

    query =
      IpRdnsCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, now)

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.filter(fn row ->
          row.status == "ok" and present?(row.hostname)
        end)
        |> Map.new(fn row -> {row.ip, String.trim(row.hostname)} end)

      _ ->
        %{}
    end
  rescue
    error ->
      Logger.debug("Failed to load attributed-flow rDNS",
        reason: inspect(error)
      )

      %{}
  end

  defp row_from_srql(%{} = row) do
    payload = map_value(row, "ocsf_payload") || %{}
    attribution = map_value(payload, "attribution") || %{}
    workload = map_value(attribution, "workload_identity") || %{}
    public_endpoint = map_value(attribution, "public_endpoint") || %{}
    pid = attribution |> map_value("pid") |> parse_int()
    uid = attribution |> map_value("uid") |> parse_int()
    protocol_num = row |> map_value("protocol_num") |> parse_int()

    %{
      id: flow_id(row, attribution),
      timestamp: map_value(row, "time"),
      source: row |> map_value("src_endpoint_ip") |> clean_string(),
      source_port: row |> map_value("src_endpoint_port") |> parse_int(),
      destination: row |> map_value("dst_endpoint_ip") |> clean_string(),
      destination_port: row |> map_value("dst_endpoint_port") |> parse_int(),
      bytes: row |> map_value("bytes_total") |> parse_int() || 0,
      packets: row |> map_value("packets_total") |> parse_int() || 0,
      protocol_num: protocol_num,
      protocol: protocol_name(map_value(row, "protocol_name"), protocol_num),
      pid: pid,
      comm: attribution |> map_value("comm") |> clean_string(),
      cmdline: attribution |> map_value("redacted_cmdline") |> clean_string(),
      uid: uid,
      container_id: attribution |> map_value("container_id") |> clean_string(),
      agent_id: attribution_agent_id(payload),
      partition: clean_string(map_value(row, "partition") || map_value(payload, "partition")),
      attributed?: not is_nil(pid),
      source_hostname: nil,
      destination_hostname: nil,
      threat: nil,
      pod_namespace: workload |> map_value("pod_namespace") |> clean_string(),
      pod_name: workload |> map_value("pod_name") |> clean_string(),
      pod_uid: workload |> map_value("pod_uid") |> clean_string(),
      container_name: workload |> map_value("container_name") |> clean_string(),
      image: clean_string(map_value(workload, "image") || map_value(workload, "image_ref")),
      runtime_source: workload |> map_value("runtime_source") |> clean_string(),
      context_name: workload |> map_value("context_name") |> clean_string(),
      workload_identity: workload,
      public_endpoint: public_endpoint,
      public_endpoint_service: public_endpoint |> map_value("service_name") |> clean_string(),
      public_endpoint_gateway: public_endpoint |> map_value("gateway_name") |> clean_string(),
      public_endpoint_class: public_endpoint |> map_value("exposure_class") |> clean_string(),
      public_endpoint_route: public_endpoint_route_label(public_endpoint),
      public_endpoint_namespace: public_endpoint |> map_value("namespace") |> clean_string(),
      raw_payload: payload
    }
  end

  defp public_endpoint_route_label(pe) when is_map(pe) do
    kind = pe |> map_value("route_kind") |> clean_string()
    name = pe |> map_value("route_name") |> clean_string()

    cond do
      present?(kind) and present?(name) -> "#{kind}/#{name}"
      present?(name) -> name
      true -> nil
    end
  end

  defp public_endpoint_route_label(_), do: nil

  defp refresh_selected_flow(nil, _rows_by_id), do: nil
  defp refresh_selected_flow(%{id: id} = selected, rows_by_id), do: Map.get(rows_by_id, id, selected)

  defp summary_count(summary, "attributed"), do: summary.attributed
  defp summary_count(summary, "unmatched"), do: summary.unmatched
  defp summary_count(summary, _), do: summary.total

  defp page_count(total, page_size) when total > 0, do: ceil(total / page_size)
  defp page_count(_total, _page_size), do: 1

  defp normalize_filter(filter) when filter in @filters, do: filter
  defp normalize_filter(_), do: @default_filter

  defp normalize_page(value) do
    case parse_int(value) do
      page when is_integer(page) and page > 0 -> page
      _ -> 1
    end
  end

  defp normalize_page_size(value) do
    value
    |> parse_int()
    |> case do
      size when is_integer(size) and size > 0 -> min(size, @max_page_size)
      _ -> @default_page_size
    end
  end

  defp patch_path(filter, page, page_size) do
    ~p"/observability/flows/attributed?#{%{filter: filter, page: page, per_page: page_size}}"
  end

  defp normalize_query(query, filter, page_size) when is_binary(query) do
    case String.trim(query) do
      "" -> query_for_filter(filter, page_size)
      q -> ensure_attributed_query(q)
    end
  end

  defp normalize_query(_query, filter, page_size), do: query_for_filter(filter, page_size)

  defp ensure_attributed_query(query) do
    if Regex.match?(~r/(^|\s)in:attributed_flows(?=\s|$)/i, query) do
      query
    else
      ~r/(^|\s)in:\S+/i
      |> Regex.replace(query, "\\1in:attributed_flows", global: false)
      |> case do
        ^query -> "in:attributed_flows #{query}"
        rewritten -> rewritten
      end
    end
  end

  defp query_for_filter(filter, page_size) do
    filter_token =
      case filter do
        "attributed" -> " attribution_status:attributed"
        "unmatched" -> " attribution_status:unmatched"
        _ -> ""
      end

    "in:attributed_flows time:last_24h#{filter_token} sort:time:desc limit:#{page_size}"
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title="Attributed Flows"
      srql={@srql}
    >
      <div class="sr-observability-page mx-auto max-w-7xl space-y-5 p-4 font-sans sm:p-6">
        <.observability_chrome
          active_pane="attributed-flows"
          title="Attributed Flows"
          subtitle="Network flow records joined with host process context."
        >
          <:actions>
            <div class="flex items-center gap-2">
              <.ui_button
                href={~p"/observability/netflows?#{%{view: "explorer"}}"}
                variant="ghost"
                size="sm"
              >
                <.icon name="hero-table-cells" class="size-4" /> Raw Flows
              </.ui_button>
            </div>
          </:actions>
        </.observability_chrome>

        <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <.summary_tile
            label="Rows"
            value={format_number(@summary.total)}
            icon="hero-table-cells"
            tone="neutral"
            filter="all"
            active={@filter == "all"}
          />
          <.summary_tile
            label="Attributed"
            value={format_number(@summary.attributed)}
            icon="hero-cpu-chip"
            tone="success"
            filter="attributed"
            active={@filter == "attributed"}
          />
          <.summary_tile
            label="Unmatched"
            value={format_number(@summary.unmatched)}
            icon="hero-link-slash"
            tone="warning"
            filter="unmatched"
            active={@filter == "unmatched"}
          />
          <.summary_tile
            label="Bytes"
            value={format_bytes(@summary.bytes)}
            icon="hero-arrow-trending-up"
            tone="info"
            filter="all"
            active={false}
          />
        </div>

        <.ui_panel class="p-0" body_class="p-0">
          <:header>
            <div class="flex w-full flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
              <div>
                <div class="text-sm font-semibold tracking-tight text-sr-ink">
                  {filter_title(@filter)}
                </div>
                <div class="text-xs leading-relaxed text-sr-muted">
                  Last {@time_window_hours} hours. Page {@page} of {@page_count}.
                </div>
              </div>
              <div class="flex items-center gap-2">
                <.ui_button
                  type="button"
                  variant={if @live?, do: "primary", else: "ghost"}
                  size="sm"
                  phx-click="toggle_live"
                  aria-label="Toggle live updates"
                  title="Toggle live updates"
                >
                  <span>Live</span>
                  <.ui_badge size="xs" variant={if @live?, do: "success", else: "ghost"}>
                    {if @live?, do: "On", else: "Off"}
                  </.ui_badge>
                </.ui_button>
                <.pagination_controls
                  page={@page}
                  page_count={@page_count}
                  filter={@filter}
                  page_size={@page_size}
                />
              </div>
            </div>
          </:header>

          <div class="hidden border-b border-sr-line px-4 py-2 text-[11px] font-semibold uppercase tracking-wider text-sr-muted lg:grid lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1.35fr)_minmax(0,1.05fr)_minmax(0,.9fr)_minmax(0,.75fr)] lg:gap-4">
            <div>Source</div>
            <div>Destination</div>
            <div>Process / Agent</div>
            <div>Traffic</div>
            <div>Status</div>
          </div>

          <div
            id="attributed-flows"
            phx-update="stream"
            class="divide-y divide-sr-line"
          >
            <%= for {dom_id, row} <- @streams.attributed_flows do %>
              <button
                type="button"
                id={dom_id}
                phx-click="open_flow"
                phx-value-id={row.id}
                class="grid w-full gap-3 px-4 py-3 text-left transition hover:bg-sr-subtle/55 focus:bg-sr-subtle/70 focus:outline-none lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1.35fr)_minmax(0,1.05fr)_minmax(0,.9fr)_minmax(0,.75fr)] lg:gap-4"
              >
                <.endpoint_summary
                  label="Source"
                  ip={row.source}
                  port={row.source_port}
                  hostname={row.source_hostname}
                />
                <.endpoint_summary
                  label="Destination"
                  ip={row.destination}
                  port={row.destination_port}
                  hostname={row.destination_hostname}
                />

                <div class="min-w-0">
                  <div class="text-[11px] font-semibold uppercase tracking-wider text-sr-muted lg:hidden">
                    Process / Agent
                  </div>
                  <div class="truncate text-sm font-semibold tracking-tight text-sr-ink">
                    {process_label(row)}
                  </div>
                  <div class="mt-0.5 truncate font-mono text-[11px] text-sr-muted">
                    {display(public_endpoint_label(row) || workload_label(row) || row.agent_id)}
                  </div>
                </div>

                <div class="min-w-0">
                  <div class="text-[11px] font-semibold uppercase tracking-wider text-sr-muted lg:hidden">
                    Traffic
                  </div>
                  <div class="flex flex-wrap items-center gap-2">
                    <.ui_badge variant="ghost" size="xs">{row.protocol}</.ui_badge>
                    <span class="text-sm font-semibold tracking-tight tabular-nums text-sr-ink">
                      {format_bytes(row.bytes)}
                    </span>
                  </div>
                  <div class="mt-0.5 text-xs tabular-nums text-sr-muted">
                    {format_number(row.packets)} packets
                  </div>
                </div>

                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <.attribution_badge attributed?={row.attributed?} />
                    <.threat_badge threat={row.threat} />
                  </div>
                  <.user_time
                    id={"attributed-flow-#{row.id}-row-time"}
                    value={row.timestamp}
                    timezone={@current_scope.user.timezone || "Etc/UTC"}
                    style={:compact}
                    class="mt-1 truncate font-mono text-[11px] text-sr-muted"
                  />
                </div>
              </button>
            <% end %>
          </div>

          <div :if={@rows == []} class="px-4 py-12 text-center">
            <div class="text-sm font-medium">
              No {filter_empty_label(@filter)} flows in the last {@time_window_hours} hours.
            </div>
            <div class="mt-1 text-xs text-sr-muted">
              Toggle to all rows or wait for the next flow-correlation cycle.
            </div>
          </div>

          <div class="border-t border-sr-line px-4 py-3">
            <.pagination_controls
              page={@page}
              page_count={@page_count}
              filter={@filter}
              page_size={@page_size}
            />
          </div>
        </.ui_panel>
      </div>

      <.flow_details_modal
        :if={@selected_flow}
        flow={@selected_flow}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
      />
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :tone, :string, default: "neutral"
  attr :filter, :string, required: true
  attr :active, :boolean, default: false

  defp summary_tile(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_filter"
      phx-value-filter={@filter}
      class={[
        "rounded-sr-control border bg-sr-surface p-3 text-left font-sans transition hover:-translate-y-px hover:shadow-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-sr-focus",
        tile_tone_class(@tone),
        @active && "ring-2 ring-sr-brand/35"
      ]}
    >
      <div class="flex items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate text-[11px] font-semibold uppercase tracking-wider text-sr-muted">
            {@label}
          </div>
          <div class="mt-1 truncate text-2xl font-semibold tracking-tight tabular-nums text-sr-ink">
            {@value}
          </div>
        </div>
        <.icon name={@icon} class="size-5 shrink-0 opacity-70" />
      </div>
    </button>
    """
  end

  attr :page, :integer, required: true
  attr :page_count, :integer, required: true
  attr :filter, :string, required: true
  attr :page_size, :integer, required: true

  defp pagination_controls(assigns) do
    assigns =
      assigns
      |> assign(:previous_page, max(assigns.page - 1, 1))
      |> assign(:next_page, min(assigns.page + 1, assigns.page_count))

    ~H"""
    <div class="flex items-center justify-between gap-2">
      <.ui_button
        type="button"
        phx-click="goto_page"
        phx-value-page={@previous_page}
        disabled={@page <= 1}
        size="xs"
        variant="ghost"
      >
        <.icon name="hero-chevron-left" class="size-3.5" /> Previous
      </.ui_button>
      <span class="min-w-20 text-center text-xs text-sr-muted tabular-nums">
        {@page} / {@page_count}
      </span>
      <.ui_button
        type="button"
        phx-click="goto_page"
        phx-value-page={@next_page}
        disabled={@page >= @page_count}
        size="xs"
        variant="ghost"
      >
        Next <.icon name="hero-chevron-right" class="size-3.5" />
      </.ui_button>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :ip, :string, required: true
  attr :port, :any, default: nil
  attr :hostname, :any, default: nil

  defp endpoint_summary(assigns) do
    ~H"""
    <div class="min-w-0">
      <div class="text-[11px] font-semibold uppercase tracking-wider text-sr-muted lg:hidden">
        {@label}
      </div>
      <div class="truncate font-mono text-[13px] font-normal tracking-tight text-sr-ink">
        {endpoint(@ip, @port)}
      </div>
      <div class="mt-0.5 truncate text-xs text-sr-muted">
        {display(@hostname)}
      </div>
    </div>
    """
  end

  attr :attributed?, :boolean, required: true

  defp attribution_badge(assigns) do
    ~H"""
    <.ui_badge variant={if @attributed?, do: "success", else: "warning"} size="xs">
      {if @attributed?, do: "Attributed", else: "Unmatched"}
    </.ui_badge>
    """
  end

  attr :threat, :any, default: nil

  defp threat_badge(%{threat: nil} = assigns) do
    ~H"""
    <.ui_badge variant="ghost" size="xs">No IOC</.ui_badge>
    """
  end

  defp threat_badge(assigns) do
    ~H"""
    <.ui_badge variant="error" size="xs">
      IOC {display(@threat.match_count)}
    </.ui_badge>
    """
  end

  attr :flow, :map, required: true
  attr :timezone, :string, required: true

  defp flow_details_modal(assigns) do
    ~H"""
    <dialog
      id="attributed-flow-details-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
      data-cancel="close_flow"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-lg">
        <div class="flex items-start justify-between gap-4 border-b border-sr-line pb-4">
          <div class="min-w-0">
            <h2 class="text-lg font-semibold tracking-tight text-sr-ink">Flow Details</h2>
            <.user_time
              id={"attributed-flow-#{@flow.id}-modal-time"}
              value={@flow.timestamp}
              timezone={@timezone}
              style={:compact}
              class="mt-1 break-all font-mono text-xs text-sr-muted"
            />
          </div>
          <.ui_icon_button
            type="button"
            phx-click="close_flow"
            aria-label="Close details"
            title="Close details"
            size="sm"
            variant="ghost"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_icon_button>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.detail_item
            label="Source"
            value={endpoint(@flow.source, @flow.source_port)}
            subvalue={@flow.source_hostname}
          />
          <.detail_item
            label="Destination"
            value={endpoint(@flow.destination, @flow.destination_port)}
            subvalue={@flow.destination_hostname}
          />
          <.detail_item label="Protocol" value={@flow.protocol} />
          <.detail_item
            label="Bytes"
            value={format_bytes(@flow.bytes)}
            subvalue={"#{format_number(@flow.bytes)} raw bytes"}
          />
          <.detail_item label="Packets" value={format_number(@flow.packets)} />
          <.detail_item label="Agent" value={display(@flow.agent_id)} subvalue={@flow.partition} />
          <.detail_item label="Context" value={display(workload_context_label(@flow))} />
          <.detail_item label="PID" value={display(@flow.pid)} subvalue={uid_label(@flow.uid)} />
          <.detail_item label="Process" value={process_label(@flow)} subvalue={@flow.cmdline} />
          <.detail_item
            label="Public endpoint"
            value={display(public_endpoint_label(@flow))}
            subvalue={public_endpoint_sublabel(@flow)}
          />
          <.detail_item
            label="Workload"
            value={display(workload_label(@flow))}
            subvalue={@flow.image}
          />
          <.detail_item
            label="Container"
            value={display(@flow.container_id)}
            subvalue={@flow.container_name}
          />
          <.detail_item
            label="Threat Intel"
            value={threat_label(@flow.threat)}
            subvalue={threat_sources(@flow.threat)}
          />
        </div>

        <div class="sr-ui-modal-action">
          <.ui_button href={netflow_details_path(@flow)} variant="primary" size="sm">
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> NetFlow Details
          </.ui_button>
        </div>
      </div>
    </dialog>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :subvalue, :any, default: nil

  defp detail_item(assigns) do
    ~H"""
    <div class="min-w-0 rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
      <div class="text-[10px] font-medium uppercase tracking-wider text-sr-muted">{@label}</div>
      <div class="mt-1 break-all font-mono text-sm leading-snug text-sr-ink">{display(@value)}</div>
      <div :if={present?(@subvalue)} class="mt-1 break-all text-xs leading-snug text-sr-muted">
        {display(@subvalue)}
      </div>
    </div>
    """
  end

  defp flow_dom_id(row), do: "attributed-flow-#{row.id}"

  defp filter_title("attributed"), do: "Attributed Flow Records"
  defp filter_title("unmatched"), do: "Unmatched Flow Records"
  defp filter_title(_), do: "All Flow Records"

  defp filter_empty_label("attributed"), do: "attributed"
  defp filter_empty_label("unmatched"), do: "unmatched"
  defp filter_empty_label(_), do: "attributed or unmatched"

  defp process_label(%{comm: comm, pid: pid}) when is_binary(comm) and comm != "" do
    if pid, do: "#{comm} ##{pid}", else: comm
  end

  defp process_label(%{pid: pid}) when is_integer(pid), do: "PID #{pid}"
  defp process_label(_), do: "No process match"

  defp public_endpoint_label(%{public_endpoint_service: service, public_endpoint_class: class})
       when is_binary(service) and service != "" do
    if is_binary(class) and class != "", do: "#{class}: #{service}", else: service
  end

  defp public_endpoint_label(%{public_endpoint_gateway: gateway}) when is_binary(gateway) and gateway != "", do: gateway

  defp public_endpoint_label(_), do: nil

  defp public_endpoint_sublabel(flow) do
    Enum.find(
      [
        flow.public_endpoint_route,
        flow.public_endpoint_namespace && flow.public_endpoint_service &&
          "#{flow.public_endpoint_namespace}/#{flow.public_endpoint_service}",
        flow.public_endpoint_gateway
      ],
      &(is_binary(&1) and &1 != "")
    )
  end

  defp workload_label(%{pod_namespace: ns, pod_name: pod} = flow) when is_binary(ns) and is_binary(pod) do
    [workload_context_label(flow), "#{ns}/#{pod}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp workload_label(%{pod_name: pod}) when is_binary(pod), do: pod
  defp workload_label(%{container_name: name}) when is_binary(name), do: name
  defp workload_label(_), do: nil

  defp workload_context_label(%{context_name: name}) when is_binary(name) and name != "", do: name
  defp workload_context_label(_), do: nil

  defp netflow_details_path(row) do
    ~p"/observability/netflows?#{%{view: "explorer", q: netflow_query(row), open_flow: "1"}}"
  end

  defp netflow_query(row) do
    [
      "in:flows",
      "time:last_24h",
      "sort:time:desc",
      maybe_query_token("src_endpoint_ip", row.source),
      maybe_query_token("dst_endpoint_ip", row.destination),
      maybe_query_token("src_endpoint_port", row.source_port),
      maybe_query_token("dst_endpoint_port", row.destination_port),
      maybe_query_token("protocol_num", row.protocol_num)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp maybe_query_token(_field, nil), do: nil
  defp maybe_query_token(_field, ""), do: nil
  defp maybe_query_token(field, value), do: "#{field}:#{srql_value(value)}"

  defp srql_value(value) when is_integer(value), do: Integer.to_string(value)

  defp srql_value(value) do
    value = to_string(value)

    if String.match?(value, ~r/^[A-Za-z0-9_.:\/-]+$/) do
      value
    else
      inspect(value)
    end
  end

  defp endpoint(ip, port) when port in [nil, ""] do
    display(ip)
  end

  defp endpoint(ip, port), do: "#{display(ip)}:#{port}"

  defp uid_label(nil), do: nil
  defp uid_label(uid), do: "UID #{uid}"

  defp threat_label(nil), do: "No IOC match"

  defp threat_label(%{match_count: count, max_severity: severity}) do
    severity_label =
      case severity do
        nil -> "severity unknown"
        value -> "severity #{value}"
      end

    "#{count} #{pluralize(count, "match", "matches")}, #{severity_label}"
  end

  defp threat_sources(nil), do: nil
  defp threat_sources(%{sources: []}), do: nil
  defp threat_sources(%{sources: sources}), do: Enum.join(sources, ", ")

  defp protocol_name(protocol, _num) when is_binary(protocol) and protocol != "", do: String.upcase(protocol)
  defp protocol_name(_protocol, 1), do: "ICMP"
  defp protocol_name(_protocol, 6), do: "TCP"
  defp protocol_name(_protocol, 17), do: "UDP"
  defp protocol_name(_protocol, 58), do: "ICMPv6"
  defp protocol_name(_protocol, num) when is_integer(num), do: "IP #{num}"
  defp protocol_name(_protocol, _num), do: "-"

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_float(v), do: trunc(v)

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(%Decimal{} = value), do: Decimal.to_integer(value)
  defp parse_int(value) when is_number(value), do: trunc(value)
  defp parse_int(value) when is_struct(value), do: value |> to_string() |> parse_int()
  defp parse_int(_), do: nil

  defp map_value(nil, _key), do: nil

  defp map_value(%{} = map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, known_atom_key(key))
  end

  defp map_value(_value, _key), do: nil

  defp known_atom_key("agent_id"), do: :agent_id
  defp known_atom_key("attribution"), do: :attribution
  defp known_atom_key("bytes_total"), do: :bytes_total
  defp known_atom_key("cmdline"), do: :cmdline
  defp known_atom_key("comm"), do: :comm
  defp known_atom_key("container_id"), do: :container_id
  defp known_atom_key("container_name"), do: :container_name
  defp known_atom_key("context_name"), do: :context_name
  defp known_atom_key("dst_endpoint_ip"), do: :dst_endpoint_ip
  defp known_atom_key("dst_endpoint_port"), do: :dst_endpoint_port
  defp known_atom_key("image"), do: :image
  defp known_atom_key("image_ref"), do: :image_ref
  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("ocsf_payload"), do: :ocsf_payload
  defp known_atom_key("packets_total"), do: :packets_total
  defp known_atom_key("partition"), do: :partition
  defp known_atom_key("pid"), do: :pid
  defp known_atom_key("pod_name"), do: :pod_name
  defp known_atom_key("pod_namespace"), do: :pod_namespace
  defp known_atom_key("pod_uid"), do: :pod_uid
  defp known_atom_key("protocol_name"), do: :protocol_name
  defp known_atom_key("protocol_num"), do: :protocol_num
  defp known_atom_key("redacted_cmdline"), do: :redacted_cmdline
  defp known_atom_key("runtime_source"), do: :runtime_source
  defp known_atom_key("src_endpoint_ip"), do: :src_endpoint_ip
  defp known_atom_key("src_endpoint_port"), do: :src_endpoint_port
  defp known_atom_key("time"), do: :time
  defp known_atom_key("uid"), do: :uid
  defp known_atom_key("workload_identity"), do: :workload_identity
  defp known_atom_key(_), do: nil

  defp attribution_agent_id(payload) do
    clean_string(map_value(payload, "agent_id") || map_value(map_value(payload, "metadata"), "agent_id"))
  end

  defp flow_id(row, attribution) do
    [
      map_value(row, "time"),
      map_value(row, "src_endpoint_ip"),
      map_value(row, "src_endpoint_port"),
      map_value(row, "dst_endpoint_ip"),
      map_value(row, "dst_endpoint_port"),
      map_value(row, "protocol_num"),
      attribution_agent_id(map_value(row, "ocsf_payload") || %{}),
      map_value(attribution, "pid")
    ]
    |> Enum.map_join("|", &to_string(&1 || ""))
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end

  defp clean_string(nil), do: nil

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      sentinel when sentinel in ["nil", "null", "undefined"] -> nil
      trimmed -> trimmed
    end
  end

  defp clean_string(value), do: to_string(value)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp display(nil), do: "-"
  defp display(""), do: "-"
  defp display(value), do: value

  defp format_number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  defp format_number(value), do: display(value)

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000_000_000 do
    "#{format_decimal(bytes / 1_000_000_000)} GB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000_000 do
    "#{format_decimal(bytes / 1_000_000)} MB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000 do
    "#{format_decimal(bytes / 1_000)} KB"
  end

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "-"

  defp format_decimal(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_, _singular, plural), do: plural

  defp tile_tone_class("success"), do: "border-sr-brand/40"
  defp tile_tone_class("warning"), do: "border-warning/40"
  defp tile_tone_class("info"), do: "border-sr-line-strong"
  defp tile_tone_class(_), do: "border-sr-line"
end
