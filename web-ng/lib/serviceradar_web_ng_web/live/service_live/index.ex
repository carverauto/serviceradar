defmodule ServiceRadarWebNGWeb.ServiceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 50
  @max_limit 200
  @summary_window "last_1h"
  @summary_limit 2000
  @gateways_default_limit 10
  @gateways_max_limit 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Services")
     |> assign(:services, [])
     |> assign(:summary, %{total: 0, available: 0, unavailable: 0, by_type: %{}, check_count: 0})
     |> assign(:limit, @default_limit)
     |> assign(:params, %{})
     |> assign(:gateways, [])
     |> assign(:gateways_limit, @gateways_default_limit)
     |> assign(:gateways_pagination, %{"prev_cursor" => nil, "next_cursor" => nil})
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
      |> assign(:params, params)

    # Compute summary from a bounded recent window, so the "By Service Type" panel reflects more
    # than just the current page of results (but remains scale-safe).
    summary = load_summary(socket)

    socket =
      socket
      |> assign(:summary, summary)
      |> load_gateways(params)

    {:noreply, socket}
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
    has_filter = is_binary(query) and Regex.match?(~r/(?:^|\s)(?:service_type|type):/, query)
    gateways_pagination = Map.get(assigns, :gateways_pagination, %{}) || %{}

    assigns =
      assigns
      |> assign(:pagination, pagination)
      |> assign(:has_filter, has_filter)
      |> assign(:gateways_pagination, gateways_pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <div class="space-y-4">
          <.gateways_panel
            params={@params}
            gateways={@gateways}
            pagination={@gateways_pagination}
            limit={@gateways_limit}
          />
          <.service_summary summary={@summary} has_filter={@has_filter} />

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

  attr :params, :map, default: %{}
  attr :gateways, :list, default: []
  attr :pagination, :map, default: %{}
  attr :limit, :integer, default: @gateways_default_limit

  defp gateways_panel(assigns) do
    gateways = assigns.gateways || []
    prev_cursor = Map.get(assigns.pagination, "prev_cursor")
    next_cursor = Map.get(assigns.pagination, "next_cursor")

    assigns =
      assigns
      |> assign(:gateways, gateways)
      |> assign(:prev_cursor, prev_cursor)
      |> assign(:next_cursor, next_cursor)
      |> assign(:has_prev, is_binary(prev_cursor) and prev_cursor != "")
      |> assign(:has_next, is_binary(next_cursor) and next_cursor != "")
      |> assign(:showing_text, gateways_pagination_text(length(gateways)))

    ~H"""
    <.ui_panel>
      <:header>
        <div class="min-w-0">
          <div class="text-sm font-semibold">Gateways</div>
          <div class="text-xs text-base-content/70">
            Gateways self-report and may not show up in service checks.
          </div>
        </div>
        <.link
          href={~p"/gateways"}
          class="text-base-content/60 hover:text-primary"
          title="View all gateways"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </:header>

      <div class="overflow-x-auto">
        <table class="table table-sm table-zebra w-full">
          <thead>
            <tr>
              <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-48">
                Gateway ID
              </th>
              <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24">
                Status
              </th>
              <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
                Address
              </th>
              <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
                Last Seen
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@gateways == []}>
              <td colspan="4" class="text-sm text-base-content/60 py-6 text-center">
                No gateways found.
              </td>
            </tr>

            <%= for {gateway, idx} <- Enum.with_index(@gateways) do %>
              <tr
                id={"services-gateway-row-#{idx}"}
                class="hover:bg-base-200/40 cursor-pointer transition-colors"
                phx-click={JS.navigate(~p"/gateways/#{gateway_id(gateway)}")}
              >
                <td
                  class="whitespace-nowrap text-xs font-mono truncate max-w-[12rem]"
                  title={gateway_id(gateway)}
                >
                  {gateway_id(gateway)}
                </td>
                <td class="whitespace-nowrap text-xs">
                  <.gateway_status_badge gateway={gateway} />
                </td>
                <td
                  class="whitespace-nowrap text-xs font-mono truncate max-w-[10rem]"
                  title={gateway_address(gateway)}
                >
                  {gateway_address(gateway)}
                </td>
                <td class="whitespace-nowrap text-xs font-mono">
                  {gateway_last_seen(gateway)}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="mt-3 pt-3 border-t border-base-200 flex items-center justify-between gap-4">
        <div class="text-sm text-base-content/60">{@showing_text}</div>
        <div class="join">
          <.link
            :if={@has_prev}
            patch={gateways_page_href(@params, @limit, @prev_cursor)}
            class="join-item btn btn-sm btn-outline"
          >
            <.icon name="hero-chevron-left" class="size-4" /> Previous
          </.link>
          <button :if={not @has_prev} class="join-item btn btn-sm btn-outline" disabled>
            <.icon name="hero-chevron-left" class="size-4" /> Previous
          </button>

          <.link
            :if={@has_next}
            patch={gateways_page_href(@params, @limit, @next_cursor)}
            class="join-item btn btn-sm btn-outline"
          >
            Next <.icon name="hero-chevron-right" class="size-4" />
          </.link>
          <button :if={not @has_next} class="join-item btn btn-sm btn-outline" disabled>
            Next <.icon name="hero-chevron-right" class="size-4" />
          </button>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :gateway, :map, required: true

  defp gateway_status_badge(assigns) do
    active = Map.get(assigns.gateway, "is_active")

    {label, variant} =
      case active do
        true -> {"Active", "success"}
        false -> {"Inactive", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assign(assigns, :label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp gateway_id(%{} = gateway) do
    Map.get(gateway, "gateway_id") || Map.get(gateway, "id") || "unknown"
  end

  defp gateway_id(_), do: "unknown"

  defp gateway_address(%{} = gateway) do
    Map.get(gateway, "address") ||
      Map.get(gateway, "gateway_address") ||
      Map.get(gateway, "host") ||
      Map.get(gateway, "hostname") ||
      Map.get(gateway, "ip") ||
      Map.get(gateway, "ip_address") ||
      "—"
  end

  defp gateway_address(_), do: "—"

  defp gateway_last_seen(%{} = gateway) do
    ts = Map.get(gateway, "last_seen") || Map.get(gateway, "updated_at")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp gateway_last_seen(_), do: "—"

  defp gateways_pagination_text(count) when is_integer(count) and count > 0 do
    "Showing #{count} gateway#{if count != 1, do: "s", else: ""}"
  end

  defp gateways_pagination_text(_), do: "No gateways"

  defp gateways_page_href(params, limit, cursor) do
    base =
      params
      |> normalize_params()
      |> Map.put("gateways_limit", limit)
      |> Map.put("gateways_cursor", cursor)
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    qs = URI.encode_query(base)
    if qs == "", do: "/services", else: "/services?" <> qs
  end

  defp normalize_params(%{} = params) do
    params
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end

  defp normalize_params(_), do: %{}

  defp load_gateways(socket, params) when is_map(params) do
    limit = parse_gateways_limit(Map.get(params, "gateways_limit"))
    cursor = normalize_optional_string(Map.get(params, "gateways_cursor"))
    query = "in:gateways sort:last_seen:desc limit:#{limit}"
    scope = get_scope(socket)

    case srql_module().query(query, %{cursor: cursor, limit: limit, scope: scope}) do
      {:ok, %{"results" => results} = resp} when is_list(results) ->
        pagination =
          case Map.get(resp, "pagination") do
            %{} = pag -> pag
            _ -> %{}
          end

        socket
        |> assign(:gateways, results)
        |> assign(:gateways_limit, limit)
        |> assign(:gateways_pagination, pagination)

      _ ->
        socket
        |> assign(:gateways, [])
        |> assign(:gateways_limit, limit)
        |> assign(:gateways_pagination, %{"prev_cursor" => nil, "next_cursor" => nil})
    end
  end

  defp load_gateways(socket, _), do: socket

  defp parse_gateways_limit(nil), do: @gateways_default_limit

  defp parse_gateways_limit(value) when is_integer(value) and value > 0,
    do: min(value, @gateways_max_limit)

  defp parse_gateways_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> parse_gateways_limit(n)
      _ -> @gateways_default_limit
    end
  end

  defp parse_gateways_limit(_), do: @gateways_default_limit

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(_), do: nil

  attr :summary, :map, required: true
  attr :has_filter, :boolean, default: false

  defp service_summary(assigns) do
    total = assigns.summary.total
    available = assigns.summary.available
    unavailable = assigns.summary.unavailable
    by_type = assigns.summary.by_type
    check_count = Map.get(assigns.summary, :check_count, 0)

    # Calculate availability percentage
    avail_pct = if total > 0, do: round(available / total * 100), else: 0

    has_filter = Map.get(assigns, :has_filter, false)

    max_type_total =
      by_type
      |> Map.values()
      |> Enum.map(fn counts ->
        Map.get(counts, :available, 0) + Map.get(counts, :unavailable, 0)
      end)
      |> case do
        [] -> 0
        values -> Enum.max(values)
      end

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:available, available)
      |> assign(:unavailable, unavailable)
      |> assign(:avail_pct, avail_pct)
      |> assign(:by_type, by_type)
      |> assign(:check_count, check_count)
      |> assign(:has_filter, has_filter)
      |> assign(:max_type_total, max_type_total)

    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
      <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">
              Unique Services
            </div>
            <div class="text-2xl font-bold">{@total}</div>
            <div class="text-xs text-base-content/50">from {@check_count} checks</div>
          </div>
          <div class="size-12 rounded-lg bg-base-200/50 flex items-center justify-center">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="size-6 text-base-content/40"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
              />
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
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="size-6 text-success"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 13l4 4L19 7"
              />
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
          <div class={[
            "size-12 rounded-lg flex items-center justify-center",
            @unavailable > 0 && "bg-error/10",
            @unavailable == 0 && "bg-base-200/50"
          ]}>
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class={[
                "size-6",
                @unavailable > 0 && "text-error",
                @unavailable == 0 && "text-base-content/40"
              ]}
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </div>
        </div>
      </div>
    </div>

    <div
      :if={map_size(@by_type) > 0}
      class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4"
    >
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <div class="text-xs text-base-content/50 uppercase tracking-wider">By Service Type</div>
          <.link
            :if={@has_filter}
            patch={~p"/services"}
            class="text-xs text-primary hover:underline"
          >
            (Reset)
          </.link>
        </div>
        <div class="flex items-center gap-1">
          <.link
            patch={
              ~p"/services?#{%{q: "in:services available:false time:last_1h sort:timestamp:desc"}}"
            }
            class="btn btn-ghost btn-xs text-error"
          >
            Failing Only
          </.link>
        </div>
      </div>
      <div class="space-y-2">
        <%= for {type, counts} <- Enum.sort_by(@by_type, fn {_, c} -> -(c.available + c.unavailable) end) |> Enum.take(8) do %>
          <.type_bar type={type} counts={counts} max_total={@max_type_total} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :type, :string, required: true
  attr :counts, :map, required: true
  attr :max_total, :integer, required: true

  defp type_bar(assigns) do
    type_total = assigns.counts.available + assigns.counts.unavailable
    avail_pct = if type_total > 0, do: round(assigns.counts.available / type_total * 100), else: 0
    fail_pct = if type_total > 0, do: 100 - avail_pct, else: 0

    volume_pct =
      cond do
        type_total <= 0 -> 0
        assigns.max_total <= 0 -> 100
        true -> max(6, round(type_total / assigns.max_total * 100))
      end

    # Build SRQL query for this service type
    type_query = "in:services service_type:\"#{assigns.type}\" time:last_1h sort:timestamp:desc"

    assigns =
      assigns
      |> assign(:type_total, type_total)
      |> assign(:avail_pct, avail_pct)
      |> assign(:fail_pct, fail_pct)
      |> assign(:volume_pct, volume_pct)
      |> assign(:type_query, type_query)

    ~H"""
    <.link
      patch={~p"/services?#{%{q: @type_query}}"}
      class="flex items-center gap-3 p-1.5 -mx-1.5 rounded-lg hover:bg-base-200/50 transition-colors cursor-pointer group"
      title={"Filter by #{@type}"}
    >
      <div class="w-28 truncate text-xs font-medium group-hover:text-primary" title={@type}>
        {@type}
      </div>
      <div class="flex-1 h-4 bg-base-200/50 rounded-full overflow-hidden">
        <div class="h-full rounded-full overflow-hidden" style={"width: #{@volume_pct}%"}>
          <div class="h-full w-full bg-success/60 relative" title={"#{@counts.available} available"}>
            <div
              :if={@fail_pct > 0}
              class="absolute inset-y-0 right-0 bg-error/70"
              style={"width: #{@fail_pct}%"}
              title={"#{@counts.unavailable} unavailable"}
            />
          </div>
        </div>
      </div>
      <div class="w-16 text-right">
        <span class="text-xs font-mono">{@type_total}</span>
        <span class="text-[10px] text-base-content/50 ml-1">({@fail_pct}% fail)</span>
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
              <td
                class="whitespace-nowrap text-xs truncate max-w-[8rem]"
                title={service_type_value(svc)}
              >
                {service_type_value(svc) || "—"}
              </td>
              <td
                class="whitespace-nowrap text-xs truncate max-w-[12rem]"
                title={service_name_value(svc)}
              >
                {service_name_value(svc) || "—"}
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
    available = normalize_available(assigns.available)

    {label, variant} =
      case available do
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

  defp load_summary(socket) do
    current_query = socket.assigns |> Map.get(:srql, %{}) |> Map.get(:query)
    summary_query = summary_query_for(current_query)
    scope = get_scope(socket)

    case srql_module().query(summary_query, %{limit: @summary_limit, scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        compute_summary(results)

      _ ->
        compute_summary(socket.assigns.services)
    end
  end

  defp summary_query_for(nil), do: "in:services time:#{@summary_window} sort:timestamp:desc"

  defp summary_query_for(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        "in:services time:#{@summary_window} sort:timestamp:desc"

      String.contains?(trimmed, "in:services") ->
        trimmed
        |> strip_tokens_for_summary()
        |> ensure_summary_time_filter()
        |> ensure_summary_sort()

      true ->
        "in:services time:#{@summary_window} sort:timestamp:desc"
    end
  end

  defp summary_query_for(_), do: "in:services time:#{@summary_window} sort:timestamp:desc"

  defp strip_tokens_for_summary(query) do
    query = Regex.replace(~r/(?:^|\s)limit:\S+/, query, "")
    query = Regex.replace(~r/(?:^|\s)sort:\S+/, query, "")
    query = Regex.replace(~r/(?:^|\s)cursor:\S+/, query, "")
    query |> String.trim() |> String.replace(~r/\s+/, " ")
  end

  defp ensure_summary_time_filter(query) do
    if Regex.match?(~r/(?:^|\s)time:\S+/, query) do
      Regex.replace(~r/(?:^|\s)time:\S+/, query, " time:#{@summary_window}")
      |> String.trim()
    else
      "#{query} time:#{@summary_window}"
    end
  end

  defp ensure_summary_sort(query) do
    if Regex.match?(~r/(?:^|\s)sort:\S+/, query) do
      query
    else
      "#{query} sort:timestamp:desc"
    end
  end

  # Compute summary stats from unique service instances (deduplicated by gateway/agent + service identity)
  # This prevents showing N status checks for the same service instance as "N services".
  #
  # Note: `in:services` is backed by the `service_status` table, which does NOT include `uid`.
  defp compute_summary(services) when is_list(services) do
    unique_services = dedupe_services(services)
    initial = base_summary(length(services))
    Enum.reduce(unique_services, initial, &accumulate_service/2)
  end

  defp compute_summary(_),
    do: %{total: 0, available: 0, unavailable: 0, by_type: %{}, check_count: 0}

  defp dedupe_services(services) do
    services
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn svc, acc ->
      Map.put_new(acc, service_identity_key(svc), svc)
    end)
    |> Map.values()
  end

  defp service_identity_key(svc) do
    gateway_id = Map.get(svc, "gateway_id") || ""
    agent_id = Map.get(svc, "agent_id") || ""
    service_type = service_type_value(svc) || ""
    service_name = service_name_value(svc) || ""

    "#{gateway_id}:#{agent_id}:#{service_type}:#{service_name}"
  end

  defp base_summary(check_count) do
    %{total: 0, available: 0, unavailable: 0, by_type: %{}, check_count: check_count}
  end

  defp accumulate_service(svc, acc) do
    is_available = normalize_available(Map.get(svc, "available")) == true
    service_type = normalize_service_type(service_type_value(svc))
    by_type = update_by_type(acc.by_type, service_type, is_available)

    %{
      acc
      | total: acc.total + 1,
        available: acc.available + if(is_available, do: 1, else: 0),
        unavailable: acc.unavailable + if(is_available, do: 0, else: 1),
        by_type: by_type
    }
  end

  defp normalize_service_type(nil), do: "unknown"
  defp normalize_service_type(""), do: "unknown"

  defp normalize_service_type(value) do
    value |> to_string() |> String.trim() |> String.downcase()
  end

  defp update_by_type(by_type, service_type, is_available) do
    Map.update(by_type, service_type, %{available: 0, unavailable: 0}, fn counts ->
      if is_available do
        Map.update!(counts, :available, &(&1 + 1))
      else
        Map.update!(counts, :unavailable, &(&1 + 1))
      end
    end)
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp normalize_available(true), do: true
  defp normalize_available(false), do: false
  defp normalize_available(1), do: true
  defp normalize_available(0), do: false

  defp normalize_available(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "true" -> true
      "t" -> true
      "1" -> true
      "false" -> false
      "f" -> false
      "0" -> false
      _ -> nil
    end
  end

  defp normalize_available(_), do: nil

  defp service_type_value(%{} = svc) do
    Map.get(svc, "service_type") ||
      Map.get(svc, "type") ||
      Map.get(svc, "check_type") ||
      Map.get(svc, "service_kind")
  end

  defp service_type_value(_), do: nil

  defp service_name_value(%{} = svc) do
    Map.get(svc, "service_name") ||
      Map.get(svc, "name") ||
      Map.get(svc, "service") ||
      Map.get(svc, "check_name")
  end

  defp service_name_value(_), do: nil

  # Extract scope from socket for Ash policy enforcement (includes actor and tenant)
  defp get_scope(socket) do
    Map.get(socket.assigns, :current_scope)
  end
end
