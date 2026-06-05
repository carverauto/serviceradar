defmodule ServiceRadarWebNGWeb.Flows.AttributedLive do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Repo

  @refresh_interval_ms 5_000
  @time_window_hours 24
  @default_filter "attributed"
  @filters ~w(attributed unmatched all)
  @default_page_size 50
  @max_page_size 100

  @summary_sql """
  SELECT
    COUNT(*)::bigint AS total,
    COUNT(*) FILTER (WHERE ocsf_payload -> 'attribution' ->> 'pid' IS NOT NULL)::bigint AS attributed,
    COUNT(*) FILTER (WHERE ocsf_payload -> 'attribution' ->> 'pid' IS NULL)::bigint AS unmatched,
    COALESCE(SUM(bytes_total), 0)::bigint AS bytes
  FROM platform.ocsf_network_activity
  WHERE ocsf_payload ->> 'event_type' = 'attributed_flow'
    AND time > now() - ($1::int * interval '1 hour')
  """

  @flows_sql """
  SELECT
    md5(concat_ws('|',
      extract(epoch from time)::text,
      COALESCE(src_endpoint_ip, ''),
      COALESCE(src_endpoint_port::text, ''),
      COALESCE(dst_endpoint_ip, ''),
      COALESCE(dst_endpoint_port::text, ''),
      COALESCE(protocol_name, protocol_num::text, ''),
      COALESCE(ocsf_payload ->> 'agent_id', ''),
      COALESCE(ocsf_payload -> 'attribution' ->> 'pid', '')
    )) AS flow_id,
    time,
    src_endpoint_ip,
    src_endpoint_port,
    dst_endpoint_ip,
    dst_endpoint_port,
    protocol_num,
    protocol_name,
    COALESCE(bytes_total, 0)::bigint,
    COALESCE(packets_total, 0)::bigint,
    ocsf_payload -> 'attribution' ->> 'pid',
    ocsf_payload -> 'attribution' ->> 'comm',
    ocsf_payload -> 'attribution' ->> 'redacted_cmdline',
    ocsf_payload -> 'attribution' ->> 'uid',
    ocsf_payload -> 'attribution' ->> 'container_id',
    COALESCE(ocsf_payload ->> 'agent_id', ocsf_payload #>> '{metadata,agent_id}'),
    COALESCE(partition, ocsf_payload ->> 'partition')
  FROM platform.ocsf_network_activity
  WHERE ocsf_payload ->> 'event_type' = 'attributed_flow'
    AND time > now() - ($1::int * interval '1 hour')
    AND (
      $2::text = 'all'
      OR ($2::text = 'attributed' AND ocsf_payload -> 'attribution' ->> 'pid' IS NOT NULL)
      OR ($2::text = 'unmatched' AND ocsf_payload -> 'attribution' ->> 'pid' IS NULL)
    )
  ORDER BY time DESC,
           src_endpoint_ip NULLS LAST,
           src_endpoint_port NULLS LAST,
           dst_endpoint_ip NULLS LAST,
           dst_endpoint_port NULLS LAST,
           protocol_num NULLS LAST
  LIMIT $3::int
  OFFSET $4::int
  """

  @rdns_sql """
  SELECT ip, hostname
  FROM platform.ip_rdns_cache
  WHERE ip = ANY($1::text[])
    AND status = 'ok'
    AND hostname IS NOT NULL
    AND hostname <> ''
    AND expires_at > now()
  """

  @threat_sql """
  SELECT ip, matched, match_count, max_severity, sources
  FROM platform.ip_threat_intel_cache
  WHERE ip = ANY($1::text[])
    AND expires_at > now()
  """

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(:page_title, "Attributed Flows")
     |> assign(:current_path, "/observability/flows/attributed")
     |> assign(:filter, @default_filter)
     |> assign(:page, 1)
     |> assign(:page_size, @default_page_size)
     |> assign(:page_count, 1)
     |> assign(:live?, true)
     |> assign(:summary, empty_summary())
     |> assign(:rows, [])
     |> assign(:rows_by_id, %{})
     |> assign(:selected_flow, nil)
     |> assign(:loading?, true)
     |> stream(:attributed_flows, [], dom_id: &flow_dom_id/1)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(:filter, normalize_filter(params["filter"]))
      |> assign(:page, normalize_page(params["page"]))
      |> assign(:page_size, normalize_page_size(params["per_page"]))
      |> assign(:selected_flow, nil)
      |> load_flows()

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: patch_path(filter, 1, socket.assigns.page_size))}
  end

  def handle_event("goto_page", %{"page" => page}, socket) do
    page = normalize_page(page)
    {:noreply, push_patch(socket, to: patch_path(socket.assigns.filter, page, socket.assigns.page_size))}
  end

  def handle_event("toggle_live", _params, socket) do
    live? = not socket.assigns.live?
    if live?, do: schedule_refresh()
    {:noreply, assign(socket, :live?, live?)}
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
    {:noreply, load_flows(socket)}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket}

  defp load_flows(socket) do
    summary = fetch_summary()
    total_for_filter = summary_count(summary, socket.assigns.filter)
    page_count = page_count(total_for_filter, socket.assigns.page_size)
    page = min(socket.assigns.page, page_count)

    rows =
      socket.assigns.filter
      |> fetch_flows(page, socket.assigns.page_size)
      |> enrich_rows()

    rows_by_id = Map.new(rows, &{&1.id, &1})
    selected_flow = refresh_selected_flow(socket.assigns.selected_flow, rows_by_id)

    socket
    |> assign(:summary, summary)
    |> assign(:page, page)
    |> assign(:page_count, page_count)
    |> assign(:rows, rows)
    |> assign(:rows_by_id, rows_by_id)
    |> assign(:selected_flow, selected_flow)
    |> assign(:loading?, false)
    |> stream(:attributed_flows, rows, reset: true, dom_id: &flow_dom_id/1)
  end

  defp fetch_summary do
    case Repo.query(@summary_sql, [@time_window_hours]) do
      {:ok, %{rows: [[total, attributed, unmatched, bytes]]}} ->
        %{total: total || 0, attributed: attributed || 0, unmatched: unmatched || 0, bytes: bytes || 0}

      _ ->
        empty_summary()
    end
  rescue
    _ -> empty_summary()
  end

  defp fetch_flows(filter, page, page_size) do
    offset = (page - 1) * page_size

    case Repo.query(@flows_sql, [@time_window_hours, filter, page_size, offset]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &row_from_db/1)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp row_from_db([
         id,
         time,
         src,
         src_port,
         dst,
         dst_port,
         protocol_num,
         protocol,
         bytes,
         packets,
         pid,
         comm,
         cmdline,
         uid,
         container_id,
         agent_id,
         partition
       ]) do
    %{
      id: id,
      timestamp: format_ts(time),
      source: clean_string(src),
      source_port: src_port,
      destination: clean_string(dst),
      destination_port: dst_port,
      bytes: bytes || 0,
      packets: packets || 0,
      protocol_num: protocol_num,
      protocol: protocol_name(protocol, protocol_num),
      pid: parse_int(pid),
      comm: clean_string(comm),
      cmdline: clean_string(cmdline),
      uid: parse_int(uid),
      container_id: clean_string(container_id),
      agent_id: clean_string(agent_id),
      partition: clean_string(partition),
      attributed?: not is_nil(parse_int(pid))
    }
  end

  defp enrich_rows([]), do: []

  defp enrich_rows(rows) do
    ips =
      rows
      |> Enum.flat_map(&[&1.source, &1.destination])
      |> Enum.filter(&present?/1)
      |> Enum.uniq()

    rdns = fetch_rdns_map(ips)
    threats = fetch_threat_map(ips)

    Enum.map(rows, fn row ->
      row
      |> Map.put(:source_hostname, Map.get(rdns, row.source))
      |> Map.put(:destination_hostname, Map.get(rdns, row.destination))
      |> Map.put(:threat, flow_threat(row, threats))
    end)
  end

  defp fetch_rdns_map([]), do: %{}

  defp fetch_rdns_map(ips) do
    case Repo.query(@rdns_sql, [ips]) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [ip, hostname] -> {ip, hostname} end)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp fetch_threat_map([]), do: %{}

  defp fetch_threat_map(ips) do
    case Repo.query(@threat_sql, [ips]) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [ip, matched, match_count, max_severity, sources] ->
          {ip,
           %{
             matched?: matched == true,
             match_count: match_count || 0,
             max_severity: max_severity,
             sources: sources || []
           }}
        end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp flow_threat(row, threats) do
    [Map.get(threats, row.source), Map.get(threats, row.destination)]
    |> Enum.filter(&match?(%{matched?: true}, &1))
    |> case do
      [] ->
        nil

      matches ->
        %{
          match_count: Enum.sum(Enum.map(matches, & &1.match_count)),
          max_severity: matches |> Enum.map(& &1.max_severity) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
          sources: matches |> Enum.flat_map(& &1.sources) |> Enum.uniq()
        }
    end
  end

  defp refresh_selected_flow(nil, _rows_by_id), do: nil
  defp refresh_selected_flow(%{id: id} = selected, rows_by_id), do: Map.get(rows_by_id, id, selected)

  defp empty_summary, do: %{total: 0, attributed: 0, unmatched: 0, bytes: 0}

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

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title="Attributed Flows"
    >
      <div class="mx-auto max-w-7xl p-4 sm:p-6 space-y-5">
        <.observability_chrome
          active_pane="attributed-flows"
          title="Attributed Flows"
          subtitle="Network flow records joined with host process context."
        >
          <:actions>
            <div class="flex items-center gap-2">
              <.ui_button
                type="button"
                variant={if @live?, do: "primary", else: "ghost"}
                size="sm"
                phx-click="toggle_live"
                aria-label="Toggle live updates"
                title="Toggle live updates"
              >
                <.icon name={if @live?, do: "hero-signal", else: "hero-pause"} class="size-4" />
                <span>Live</span>
              </.ui_button>
              <.ui_button
                href={~p"/observability?#{%{tab: "netflows", view: "explorer"}}"}
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
                <div class="text-sm font-semibold">{filter_title(@filter)}</div>
                <div class="text-xs text-base-content/60">
                  Last {@time_window_hours} hours. Page {@page} of {@page_count}.
                </div>
              </div>
              <div class="flex items-center gap-2">
                <.pagination_controls
                  page={@page}
                  page_count={@page_count}
                  filter={@filter}
                  page_size={@page_size}
                />
              </div>
            </div>
          </:header>

          <div class="hidden border-b border-base-200 px-4 py-2 text-[11px] font-semibold uppercase tracking-wide text-base-content/50 lg:grid lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1.35fr)_minmax(0,1.05fr)_minmax(0,.9fr)_minmax(0,.75fr)] lg:gap-4">
            <div>Source</div>
            <div>Destination</div>
            <div>Process / Agent</div>
            <div>Traffic</div>
            <div>Status</div>
          </div>

          <div
            id="attributed-flows"
            phx-update="stream"
            class="divide-y divide-base-200"
          >
            <%= for {dom_id, row} <- @streams.attributed_flows do %>
              <button
                type="button"
                id={dom_id}
                phx-click="open_flow"
                phx-value-id={row.id}
                class="grid w-full gap-3 px-4 py-3 text-left transition hover:bg-base-200/55 focus:bg-base-200/70 focus:outline-none lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1.35fr)_minmax(0,1.05fr)_minmax(0,.9fr)_minmax(0,.75fr)] lg:gap-4"
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
                  <div class="text-xs uppercase tracking-wide text-base-content/50 lg:hidden">
                    Process / Agent
                  </div>
                  <div class="truncate text-sm font-medium">
                    {process_label(row)}
                  </div>
                  <div class="mt-0.5 truncate font-mono text-xs text-base-content/55">
                    {display(row.agent_id)}
                  </div>
                </div>

                <div class="min-w-0">
                  <div class="text-xs uppercase tracking-wide text-base-content/50 lg:hidden">
                    Traffic
                  </div>
                  <div class="flex flex-wrap items-center gap-2">
                    <.ui_badge variant="ghost" size="xs">{row.protocol}</.ui_badge>
                    <span class="text-sm font-semibold tabular-nums">{format_bytes(row.bytes)}</span>
                  </div>
                  <div class="mt-0.5 text-xs text-base-content/55 tabular-nums">
                    {format_number(row.packets)} packets
                  </div>
                </div>

                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <.attribution_badge attributed?={row.attributed?} />
                    <.threat_badge threat={row.threat} />
                  </div>
                  <div class="mt-1 truncate text-xs text-base-content/55">{row.timestamp}</div>
                </div>
              </button>
            <% end %>
          </div>

          <div :if={@rows == []} class="px-4 py-12 text-center">
            <div class="text-sm font-medium">
              No {filter_empty_label(@filter)} flows in the last {@time_window_hours} hours.
            </div>
            <div class="mt-1 text-xs text-base-content/60">
              Toggle to all rows or wait for the next flow-correlation cycle.
            </div>
          </div>

          <div class="border-t border-base-200 px-4 py-3">
            <.pagination_controls
              page={@page}
              page_count={@page_count}
              filter={@filter}
              page_size={@page_size}
            />
          </div>
        </.ui_panel>
      </div>

      <.flow_details_modal :if={@selected_flow} flow={@selected_flow} />
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
        "rounded-lg border bg-base-100 p-3 text-left transition hover:-translate-y-px hover:shadow-sm focus:outline-none focus:ring-2 focus:ring-primary/30",
        tile_tone_class(@tone),
        @active && "ring-2 ring-primary/35"
      ]}
    >
      <div class="flex items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate text-xs uppercase text-base-content/60">{@label}</div>
          <div class="mt-1 truncate text-2xl font-semibold tabular-nums">{@value}</div>
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
      <button
        type="button"
        phx-click="goto_page"
        phx-value-page={@previous_page}
        disabled={@page <= 1}
        class="btn btn-ghost btn-xs"
      >
        <.icon name="hero-chevron-left" class="size-3.5" /> Previous
      </button>
      <span class="min-w-20 text-center text-xs text-base-content/60 tabular-nums">
        {@page} / {@page_count}
      </span>
      <button
        type="button"
        phx-click="goto_page"
        phx-value-page={@next_page}
        disabled={@page >= @page_count}
        class="btn btn-ghost btn-xs"
      >
        Next <.icon name="hero-chevron-right" class="size-3.5" />
      </button>
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
      <div class="text-xs uppercase tracking-wide text-base-content/50 lg:hidden">{@label}</div>
      <div class="truncate font-mono text-sm font-medium">
        {endpoint(@ip, @port)}
      </div>
      <div class="mt-0.5 truncate text-xs text-base-content/55">
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

  defp flow_details_modal(assigns) do
    ~H"""
    <div class="modal modal-open" role="dialog" aria-modal="true">
      <div class="modal-box max-w-4xl">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h2 class="truncate text-lg font-semibold">Flow Details</h2>
            <div class="mt-1 text-xs text-base-content/60">{@flow.timestamp}</div>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="close_flow"
            aria-label="Close details"
            title="Close details"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="mt-4 grid gap-3 md:grid-cols-2">
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
          <.detail_item label="PID" value={display(@flow.pid)} subvalue={uid_label(@flow.uid)} />
          <.detail_item label="Process" value={process_label(@flow)} subvalue={@flow.cmdline} />
          <.detail_item label="Container" value={display(@flow.container_id)} />
          <.detail_item
            label="Threat Intel"
            value={threat_label(@flow.threat)}
            subvalue={threat_sources(@flow.threat)}
          />
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_flow">close</button>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :subvalue, :any, default: nil

  defp detail_item(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
      <div class="text-xs uppercase tracking-wide text-base-content/50">{@label}</div>
      <div class="mt-1 break-words font-mono text-sm">{display(@value)}</div>
      <div :if={present?(@subvalue)} class="mt-1 break-words text-xs text-base-content/60">
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

  defp iso(%DateTime{} = t), do: DateTime.to_iso8601(t)
  defp iso(%NaiveDateTime{} = t), do: NaiveDateTime.to_iso8601(t)
  defp iso(other), do: to_string(other)

  defp format_ts(%DateTime{} = t), do: t |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_ts(%NaiveDateTime{} = t) do
    t
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
    |> Kernel.<>("Z")
  end

  defp format_ts(other), do: iso(other)

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp clean_string(nil), do: nil

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
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

  defp tile_tone_class("success"), do: "border-success/30"
  defp tile_tone_class("warning"), do: "border-warning/30"
  defp tile_tone_class("info"), do: "border-info/30"
  defp tile_tone_class(_), do: "border-base-200"
end
