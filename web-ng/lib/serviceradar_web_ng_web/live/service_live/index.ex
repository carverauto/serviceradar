defmodule ServiceRadarWebNGWeb.ServiceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents
  import ServiceRadarWebNGWeb.PluginResults

  alias ServiceRadar.Observability.{ServiceState, ServiceStatePubSub, ServiceStatusPubSub}
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 50
  @max_limit 200
  @refresh_debounce_ms 750

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ServiceStatusPubSub.subscribe()
      ServiceStatePubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Services")
     |> assign(:services, [])
     |> assign(:selected_service, nil)
     |> assign(:selected_details, %{})
     |> assign(:selected_display, [])
     |> assign(:selected_display_contract, %{})
     |> assign(:summary, %{
       total: 0,
       available: 0,
       unavailable: 0,
       by_check: %{},
       check_count: 0,
       last_updated: nil
     })
     |> assign(:limit, @default_limit)
     |> assign(:params, %{})
     |> assign(:refresh_pending, false)
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

    # Compute summary from the latest status per service identity (bounded by summary limit).
    summary = load_summary(socket)

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

  def handle_event("select_service", %{"index" => index}, socket) do
    idx = parse_int(index)
    service = Enum.at(socket.assigns.services, idx)

    if is_map(service) do
      details = parse_service_details(service)
      contract = load_display_contract(details, socket.assigns.current_scope)

      display =
        details
        |> extract_display_instructions()
        |> filter_display_by_contract(contract)

      {:noreply,
       socket
       |> assign(:selected_service, service)
       |> assign(:selected_details, details)
       |> assign(:selected_display, display)
       |> assign(:selected_display_contract, contract)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_service", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_service, nil)
     |> assign(:selected_details, %{})
     |> assign(:selected_display, [])
     |> assign(:selected_display_contract, %{})}
  end

  @impl true
  def handle_info({:service_status_updated, _status}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:service_state_updated, _state}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:refresh_services, socket) do
    {:noreply, refresh_services(socket)}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    query = Map.get(assigns.srql, :query, "")

    has_filter =
      is_binary(query) and
        Regex.match?(~r/(?:^|\s)(?:service_name|service_type|type|service):/, query)

    assigns =
      assigns
      |> assign(:pagination, pagination)
      |> assign(:has_filter, has_filter)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <div class="space-y-4">
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

            <.service_details_panel
              :if={@selected_service}
              service={@selected_service}
              details={@selected_details}
              display={@selected_display}
              display_contract={@selected_display_contract}
            />

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

  attr :summary, :map, required: true
  attr :has_filter, :boolean, default: false

  defp service_summary(assigns) do
    total = assigns.summary.total
    available = assigns.summary.available
    unavailable = assigns.summary.unavailable
    by_check = assigns.summary.by_check
    check_count = Map.get(assigns.summary, :check_count, 0)
    last_updated = Map.get(assigns.summary, :last_updated)

    # Calculate availability percentage
    avail_pct = if total > 0, do: round(available / total * 100), else: 0

    has_filter = Map.get(assigns, :has_filter, false)

    max_check_total =
      by_check
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
      |> assign(:by_check, by_check)
      |> assign(:check_count, check_count)
      |> assign(:has_filter, has_filter)
      |> assign(:max_check_total, max_check_total)
      |> assign(:last_updated, last_updated)

    ~H"""
    <div class="flex items-center justify-between text-xs text-base-content/60">
      <div>Latest status per service</div>
      <div :if={@last_updated}>
        Last updated {format_last_updated(@last_updated)}
      </div>
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
      <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">
              Services
            </div>
            <div class="text-2xl font-bold">{@total}</div>
            <div class="text-xs text-base-content/50">active services</div>
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
      :if={map_size(@by_check) > 0}
      class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4"
    >
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <div class="text-xs text-base-content/50 uppercase tracking-wider">By Check</div>
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
            patch={~p"/services?#{%{q: "in:services available:false sort:timestamp:desc"}}"}
            class="btn btn-ghost btn-xs text-error"
          >
            Failing Only
          </.link>
        </div>
      </div>
      <div class="space-y-2">
        <%= for {name, counts} <- Enum.sort_by(@by_check, fn {_, c} -> -(c.available + c.unavailable) end) |> Enum.take(8) do %>
          <.check_bar check={name} counts={counts} max_total={@max_check_total} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :check, :string, required: true
  attr :counts, :map, required: true
  attr :max_total, :integer, required: true

  defp check_bar(assigns) do
    check_total = assigns.counts.available + assigns.counts.unavailable

    avail_pct =
      if check_total > 0, do: round(assigns.counts.available / check_total * 100), else: 0

    fail_pct = if check_total > 0, do: 100 - avail_pct, else: 0

    volume_pct =
      cond do
        check_total <= 0 -> 0
        assigns.max_total <= 0 -> 100
        true -> max(6, round(check_total / assigns.max_total * 100))
      end

    # Build SRQL query for this check
    check_query =
      "in:services service_name:\"#{escape_srql_value(assigns.check)}\" sort:timestamp:desc"

    assigns =
      assigns
      |> assign(:check_total, check_total)
      |> assign(:avail_pct, avail_pct)
      |> assign(:fail_pct, fail_pct)
      |> assign(:volume_pct, volume_pct)
      |> assign(:check_query, check_query)

    ~H"""
    <.link
      patch={~p"/services?#{%{q: @check_query}}"}
      class="flex items-center gap-3 p-1.5 -mx-1.5 rounded-lg hover:bg-base-200/50 transition-colors cursor-pointer group"
      title={"Filter by #{@check}"}
    >
      <div class="w-28 truncate text-xs font-medium group-hover:text-primary" title={@check}>
        {@check}
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
        <span class="text-xs font-mono">{@check_total}</span>
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
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer"
              phx-click="select_service"
              phx-value-index={idx}
            >
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

  attr :service, :map, required: true
  attr :details, :map, default: %{}
  attr :display, :list, default: []
  attr :display_contract, :map, default: %{}

  defp service_details_panel(assigns) do
    service_name = service_name_value(assigns.service) || "Service"
    service_type = service_type_value(assigns.service) || "—"
    status = Map.get(assigns.details, "status") || Map.get(assigns.service, "status")
    summary = Map.get(assigns.details, "summary") || Map.get(assigns.service, "message")
    schema_version = resolve_schema_version(assigns.details, assigns.display_contract)

    assigns =
      assigns
      |> assign(:service_name, service_name)
      |> assign(:service_type, service_type)
      |> assign(:status, status)
      |> assign(:summary, summary)
      |> assign(:schema_version, schema_version)

    ~H"""
    <div class="mt-4 rounded-xl border border-base-200 bg-base-100 p-4 space-y-3">
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-sm font-semibold">{@service_name}</div>
          <div class="text-xs text-base-content/60">{@service_type}</div>
        </div>
        <div class="flex items-center gap-2">
          <.ui_badge size="xs" variant={status_variant(@status)}>
            {format_status(@status)}
          </.ui_badge>
          <button class="btn btn-ghost btn-xs" phx-click="clear_service">Close</button>
        </div>
      </div>

      <div :if={@summary} class="text-xs text-base-content/70">{@summary}</div>

      <div :if={@schema_version} class="text-[11px] text-base-content/50">
        UI schema version {@schema_version}
      </div>

      <.plugin_results display={@display} />
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

  defp format_status(nil), do: "UNKNOWN"
  defp format_status(status) when is_binary(status), do: String.upcase(status)
  defp format_status(status), do: to_string(status)

  defp status_variant(status) do
    case String.upcase(to_string(status || "")) do
      "OK" -> "success"
      "WARNING" -> "warning"
      "CRITICAL" -> "error"
      "FAIL" -> "error"
      _ -> "ghost"
    end
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

  defp service_timestamp_sort_key(svc) do
    case parse_timestamp(Map.get(svc, "timestamp")) do
      {:ok, dt} -> {1, DateTime.to_unix(dt, :nanosecond)}
      _ -> {0, 0}
    end
  end

  defp latest_timestamp(services) do
    Enum.reduce(services, nil, fn
      %{} = svc, acc ->
        case parse_timestamp(Map.get(svc, "timestamp")) do
          {:ok, dt} ->
            case acc do
              nil -> dt
              current -> if DateTime.compare(dt, current) == :gt, do: dt, else: current
            end

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp latest_state_timestamp(states) do
    Enum.reduce(states, nil, fn
      %ServiceState{last_observed_at: %DateTime{} = dt}, nil ->
        dt

      %ServiceState{last_observed_at: %DateTime{} = dt}, acc ->
        if DateTime.compare(dt, acc) == :gt, do: dt, else: acc

      _, acc ->
        acc
    end)
  end

  defp format_last_updated(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_last_updated(_), do: "—"

  defp load_summary(socket) do
    scope = get_scope(socket)

    case load_active_states(scope) do
      {:ok, states} when is_list(states) ->
        compute_state_summary(states)

      _ ->
        compute_summary(socket.assigns.services)
    end
  end

  defp load_active_states(scope) do
    ServiceState
    |> Ash.Query.for_read(:active, %{})
    |> Ash.read(scope: scope)
  end

  # Compute summary stats from unique service instances (deduplicated by agent + service identity)
  # This prevents showing N status checks for the same service instance as "N services".
  #
  # Note: `in:services` is backed by the `service_status` table, which does NOT include `uid`.
  defp compute_summary(services) when is_list(services) do
    unique_services = dedupe_services(services)
    last_updated = latest_timestamp(services)
    initial = base_summary(length(services), last_updated)
    Enum.reduce(unique_services, initial, &accumulate_service/2)
  end

  defp compute_summary(_),
    do: %{
      total: 0,
      available: 0,
      unavailable: 0,
      by_check: %{},
      check_count: 0,
      last_updated: nil
    }

  defp compute_state_summary(states) when is_list(states) do
    last_updated = latest_state_timestamp(states)
    initial = base_summary(length(states), last_updated)

    Enum.reduce(states, initial, fn state, acc ->
      is_available = state.available == true
      check_name = normalize_service_name(state.service_name)
      by_check = update_by_check(acc.by_check, check_name, is_available)

      %{
        acc
        | total: acc.total + 1,
          available: acc.available + if(is_available, do: 1, else: 0),
          unavailable: acc.unavailable + if(is_available, do: 0, else: 1),
          by_check: by_check
      }
    end)
  end

  defp compute_state_summary(_),
    do: %{
      total: 0,
      available: 0,
      unavailable: 0,
      by_check: %{},
      check_count: 0,
      last_updated: nil
    }

  defp schedule_refresh(socket) do
    if socket.assigns.refresh_pending do
      socket
    else
      Process.send_after(self(), :refresh_services, @refresh_debounce_ms)
      assign(socket, :refresh_pending, true)
    end
  end

  defp refresh_services(socket) do
    params = socket.assigns.params || %{}
    uri = Map.get(socket.assigns, :srql, %{}) |> Map.get(:page_path) || "/services"

    socket =
      socket
      |> SRQLPage.load_list(params, uri, :services,
        default_limit: @default_limit,
        max_limit: @max_limit
      )
      |> assign(:params, params)

    summary = load_summary(socket)

    socket
    |> assign(:summary, summary)
    |> assign(:refresh_pending, false)
  end

  defp dedupe_services(services) do
    services
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&service_timestamp_sort_key/1, :desc)
    |> Enum.reduce(%{}, fn svc, acc ->
      Map.put_new(acc, service_identity_key(svc), svc)
    end)
    |> Map.values()
  end

  defp service_identity_key(svc) do
    agent_id = Map.get(svc, "agent_id") || ""
    partition = Map.get(svc, "partition") || Map.get(svc, "partition_id") || ""
    service_type = service_type_value(svc) || ""
    service_name = service_name_value(svc) || ""

    "#{agent_id}:#{partition}:#{service_type}:#{service_name}"
  end

  defp base_summary(check_count, last_updated) do
    %{
      total: 0,
      available: 0,
      unavailable: 0,
      by_check: %{},
      check_count: check_count,
      last_updated: last_updated
    }
  end

  defp accumulate_service(svc, acc) do
    is_available = normalize_available(Map.get(svc, "available")) == true
    check_name = normalize_service_name(service_name_value(svc))
    by_check = update_by_check(acc.by_check, check_name, is_available)

    %{
      acc
      | total: acc.total + 1,
        available: acc.available + if(is_available, do: 1, else: 0),
        unavailable: acc.unavailable + if(is_available, do: 0, else: 1),
        by_check: by_check
    }
  end

  defp normalize_service_name(nil), do: "unknown"
  defp normalize_service_name(""), do: "unknown"
  defp normalize_service_name(value), do: value |> to_string() |> String.trim()

  defp update_by_check(by_check, check_name, is_available) do
    Map.update(by_check, check_name, %{available: 0, unavailable: 0}, fn counts ->
      if is_available do
        Map.update!(counts, :available, &(&1 + 1))
      else
        Map.update!(counts, :unavailable, &(&1 + 1))
      end
    end)
  end

  defp escape_srql_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
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

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> -1
    end
  end

  defp parse_int(_), do: -1

  defp parse_service_details(service) do
    details = Map.get(service, "details") || Map.get(service, :details)

    cond do
      is_map(details) -> details
      is_binary(details) -> parse_details_json(details)
      true -> %{}
    end
  end

  defp parse_details_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp parse_details_json(_), do: %{}

  defp extract_display_instructions(details) when is_map(details) do
    Map.get(details, "display") ||
      get_in(details, ["ui", "display"]) ||
      []
  end

  defp extract_display_instructions(_), do: []

  defp filter_display_by_contract(display, contract) when is_list(display) and is_map(contract) do
    allowed = Map.get(contract, "widgets") || Map.get(contract, :widgets) || []

    if is_list(allowed) and allowed != [] do
      Enum.filter(display, fn item ->
        widget = Map.get(item, "widget") || Map.get(item, :widget)
        is_binary(widget) and widget in allowed
      end)
    else
      display
    end
  end

  defp filter_display_by_contract(display, _contract), do: display

  defp load_display_contract(details, scope) when is_map(details) do
    plugin_id = get_in(details, ["labels", "plugin_id"]) || get_in(details, [:labels, :plugin_id])

    if is_binary(plugin_id) and plugin_id != "" do
      Packages.list(%{"plugin_id" => plugin_id, "status" => "approved", "limit" => 1},
        scope: scope
      )
      |> List.first()
      |> case do
        %{display_contract: contract} when is_map(contract) -> contract
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp load_display_contract(_details, _scope), do: %{}

  defp resolve_schema_version(details, contract) do
    detail_version =
      Map.get(details, "schema_version") || get_in(details, ["display", "schema_version"])

    contract_version = Map.get(contract, "schema_version") || Map.get(contract, :schema_version)

    cond do
      is_integer(detail_version) -> detail_version
      is_integer(contract_version) -> contract_version
      true -> nil
    end
  end

  # Extract scope from socket for Ash policy enforcement (includes actor)
  defp get_scope(socket) do
    Map.get(socket.assigns, :current_scope)
  end
end
