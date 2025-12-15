defmodule ServiceRadarWebNGWeb.ServiceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 50
  @max_limit 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Services")
     |> assign(:services, [])
     |> assign(:summary, %{total: 0, available: 0, unavailable: 0, by_type: %{}, check_count: 0})
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("services", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> SRQLPage.load_list(params, uri, :services,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    # Compute summary from current page results (scale-friendly: works on bounded data)
    summary = compute_summary(socket.assigns.services)

    {:noreply, assign(socket, :summary, summary)}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/services")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "services")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/services")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "services")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "services")}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    query = Map.get(assigns.srql, :query, "")
    has_filter = query != "" and query != nil
    assigns = assign(assigns, :pagination, pagination) |> assign(:has_filter, has_filter) |> assign(:current_query, query)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <div class="space-y-4">
          <.active_filter_banner :if={@has_filter} query={@current_query} />
          <.service_summary summary={@summary} />

          <.ui_panel>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">Service Checks</div>
                <div class="text-xs text-base-content/70">
                  Recent status checks from this page ({length(@services)} results).
                </div>
              </div>
            </:header>

            <.services_table id="services" services={@services} />

            <div class="mt-4 pt-4 border-t border-base-200">
              <.ui_pagination
                prev_cursor={Map.get(@pagination, "prev_cursor")}
                next_cursor={Map.get(@pagination, "next_cursor")}
                base_path="/services"
                query={Map.get(@srql, :query, "")}
                limit={@limit}
                result_count={length(@services)}
              />
            </div>
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :query, :string, required: true

  defp active_filter_banner(assigns) do
    ~H"""
    <div class="rounded-lg bg-info/10 border border-info/20 p-3 flex items-center justify-between gap-3">
      <div class="flex items-center gap-2 min-w-0">
        <.icon name="hero-funnel" class="size-4 text-info shrink-0" />
        <span class="text-sm text-base-content/80 truncate">
          Filtered view: <span class="font-mono text-xs">{truncate_query(@query)}</span>
        </span>
      </div>
      <.link patch={~p"/services"} class="btn btn-ghost btn-sm gap-1">
        <.icon name="hero-x-mark" class="size-4" />
        Clear Filter
      </.link>
    </div>
    """
  end

  defp truncate_query(query) when is_binary(query) do
    if String.length(query) > 60 do
      String.slice(query, 0, 60) <> "..."
    else
      query
    end
  end

  defp truncate_query(_), do: ""

  attr :summary, :map, required: true

  defp service_summary(assigns) do
    total = assigns.summary.total
    available = assigns.summary.available
    unavailable = assigns.summary.unavailable
    by_type = assigns.summary.by_type
    check_count = Map.get(assigns.summary, :check_count, 0)

    # Calculate availability percentage
    avail_pct = if total > 0, do: round(available / total * 100), else: 0

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:available, available)
      |> assign(:unavailable, unavailable)
      |> assign(:avail_pct, avail_pct)
      |> assign(:by_type, by_type)
      |> assign(:check_count, check_count)

    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
      <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">Unique Services</div>
            <div class="text-2xl font-bold">{@total}</div>
            <div class="text-xs text-base-content/50">from {@check_count} checks</div>
          </div>
          <div class="size-12 rounded-lg bg-base-200/50 flex items-center justify-center">
            <svg xmlns="http://www.w3.org/2000/svg" class="size-6 text-base-content/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
          </div>
        </div>
      </div>

      <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">Available</div>
            <div class="text-2xl font-bold text-success">{@available}</div>
            <div class="text-xs text-base-content/50">{@avail_pct}% healthy</div>
          </div>
          <div class="size-12 rounded-lg bg-success/10 flex items-center justify-center">
            <svg xmlns="http://www.w3.org/2000/svg" class="size-6 text-success" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
            </svg>
          </div>
        </div>
      </div>

      <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">Unavailable</div>
            <div class={["text-2xl font-bold", @unavailable > 0 && "text-error"]}>{@unavailable}</div>
            <div class="text-xs text-base-content/50">{100 - @avail_pct}% failing</div>
          </div>
          <div class={["size-12 rounded-lg flex items-center justify-center", @unavailable > 0 && "bg-error/10", @unavailable == 0 && "bg-base-200/50"]}>
            <svg xmlns="http://www.w3.org/2000/svg" class={["size-6", @unavailable > 0 && "text-error", @unavailable == 0 && "text-base-content/40"]} fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </div>
        </div>
      </div>
    </div>

    <div :if={map_size(@by_type) > 0} class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="text-xs text-base-content/50 uppercase tracking-wider">By Service Type</div>
        <div class="flex items-center gap-1">
          <.link
            patch={~p"/services"}
            class="btn btn-ghost btn-xs"
          >
            All Services
          </.link>
          <.link
            patch={~p"/services?#{%{q: "in:services available:false time:last_1h sort:timestamp:desc"}}"}
            class="btn btn-ghost btn-xs text-error"
          >
            Failing Only
          </.link>
        </div>
      </div>
      <div class="space-y-2">
        <%= for {type, counts} <- Enum.sort_by(@by_type, fn {_, c} -> -(c.available + c.unavailable) end) |> Enum.take(8) do %>
          <.type_bar type={type} counts={counts} total={@total} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :type, :string, required: true
  attr :counts, :map, required: true
  attr :total, :integer, required: true

  defp type_bar(assigns) do
    type_total = assigns.counts.available + assigns.counts.unavailable
    avail_pct = if type_total > 0, do: round(assigns.counts.available / type_total * 100), else: 0
    bar_width = if assigns.total > 0, do: max(2, round(type_total / assigns.total * 100)), else: 0

    # Build SRQL query for this service type
    type_query = "in:services service_type:\"#{assigns.type}\" time:last_1h sort:timestamp:desc"

    assigns =
      assigns
      |> assign(:type_total, type_total)
      |> assign(:avail_pct, avail_pct)
      |> assign(:bar_width, bar_width)
      |> assign(:type_query, type_query)

    ~H"""
    <.link
      patch={~p"/services?#{%{q: @type_query}}"}
      class="flex items-center gap-3 p-1.5 -mx-1.5 rounded-lg hover:bg-base-200/50 transition-colors cursor-pointer group"
      title={"Filter by #{@type}"}
    >
      <div class="w-28 truncate text-xs font-medium group-hover:text-primary" title={@type}>{@type}</div>
      <div class="flex-1 h-4 bg-base-200/50 rounded-full overflow-hidden flex">
        <div
          class="h-full bg-success/70 transition-all"
          style={"width: #{@avail_pct}%"}
          title={"#{@counts.available} available"}
        />
        <div
          class="h-full bg-error/70 transition-all"
          style={"width: #{100 - @avail_pct}%"}
          title={"#{@counts.unavailable} unavailable"}
        />
      </div>
      <div class="w-16 text-right">
        <span class="text-xs font-mono">{@type_total}</span>
        <span class="text-[10px] text-base-content/50 ml-1">({@avail_pct}%)</span>
      </div>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :services, :list, default: []

  defp services_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-20">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-28">
              Type
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Service
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Message
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@services == []}>
            <td colspan="5" class="text-sm text-base-content/60 py-8 text-center">
              No services found.
            </td>
          </tr>

          <%= for {svc, idx} <- Enum.with_index(@services) do %>
            <tr id={"#{@id}-row-#{idx}"} class="hover:bg-base-200/40">
              <td class="whitespace-nowrap text-xs font-mono">
                {format_timestamp(svc)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.status_badge available={Map.get(svc, "available")} />
              </td>
              <td class="whitespace-nowrap text-xs truncate max-w-[8rem]" title={Map.get(svc, "service_type")}>
                {Map.get(svc, "service_type") || "—"}
              </td>
              <td class="whitespace-nowrap text-xs truncate max-w-[12rem]" title={Map.get(svc, "service_name")}>
                {Map.get(svc, "service_name") || "—"}
              </td>
              <td class="text-xs truncate max-w-[28rem]" title={Map.get(svc, "message")}>
                {Map.get(svc, "message") || "—"}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :available, :any, default: nil

  defp status_badge(assigns) do
    {label, variant} =
      case assigns.available do
        true -> {"OK", "success"}
        false -> {"FAIL", "error"}
        _ -> {"—", "ghost"}
      end

    assigns = assign(assigns, :label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp format_timestamp(svc) do
    ts = Map.get(svc, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp parse_timestamp(nil), do: :error
  defp parse_timestamp(""), do: :error

  defp parse_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp parse_timestamp(_), do: :error

  # Compute summary stats from unique services (deduplicated by device_id:service_name)
  # This prevents showing 50 checks for the same 5 services as "50 services"
  defp compute_summary(services) when is_list(services) do
    # First, deduplicate by device_id:service_name, keeping most recent (first in sorted list)
    unique_services =
      services
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn svc, acc ->
        device_id = Map.get(svc, "device_id") || ""
        service_name = Map.get(svc, "service_name") || ""
        key = "#{device_id}:#{service_name}"

        # Keep first occurrence (most recent if sorted by timestamp desc)
        Map.put_new(acc, key, svc)
      end)
      |> Map.values()

    # Now compute summary from unique services only
    initial = %{total: 0, available: 0, unavailable: 0, by_type: %{}, check_count: length(services)}

    result =
      Enum.reduce(unique_services, initial, fn svc, acc ->
        is_available = Map.get(svc, "available") == true
        service_type = Map.get(svc, "service_type") || "unknown"

        by_type =
          Map.update(acc.by_type, service_type, %{available: 0, unavailable: 0}, fn counts ->
            if is_available do
              Map.update!(counts, :available, &(&1 + 1))
            else
              Map.update!(counts, :unavailable, &(&1 + 1))
            end
          end)

        %{
          acc
          | total: acc.total + 1,
            available: acc.available + if(is_available, do: 1, else: 0),
            unavailable: acc.unavailable + if(is_available, do: 0, else: 1),
            by_type: by_type
        }
      end)

    result
  end

  defp compute_summary(_), do: %{total: 0, available: 0, unavailable: 0, by_type: %{}, check_count: 0}
end
