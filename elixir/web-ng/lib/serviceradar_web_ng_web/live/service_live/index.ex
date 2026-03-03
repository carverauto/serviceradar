defmodule ServiceRadarWebNGWeb.ServiceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Observability.{ServiceState, ServiceStatePubSub, ServiceStatusPubSub}
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 50
  @max_limit 200
  @refresh_debounce_ms 750
  @active_state_window_ms :timer.minutes(15)
  @default_query "in:services time:last_1h sort:timestamp:desc limit:500"

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
     |> SRQLPage.init("services", default_limit: @default_limit)
     |> stream(:service_cards, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    params = ensure_default_query(params)

    socket =
      socket
      |> SRQLPage.load_list(params, uri, :services,
        default_limit: @default_limit,
        max_limit: @max_limit
      )
      |> assign(:params, params)

    # Compute summary from the latest status per service identity (bounded by summary limit).
    summary = load_summary(socket)
    cards = build_service_cards(socket.assigns.services, socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:summary, summary)
     |> stream(:service_cards, cards, reset: true)}
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
                <div class="text-sm font-semibold">Active Service Checks</div>
                <div class="text-xs text-base-content/70">
                  Latest plugin check per service (sorted with failures first).
                </div>
              </div>
            </:header>

            <.service_card_grid cards={@streams.service_cards} />
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
    window_minutes = div(@active_state_window_ms, 60_000)

    active_label =
      if window_minutes > 0 do
        "active services (last #{window_minutes}m)"
      else
        "active services"
      end

    assigns = assign(assigns, :active_label, active_label)

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
      <div>Latest plugin check per service</div>
      <div :if={@last_updated}>
        Last updated {format_last_updated(@last_updated)}
      </div>
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
      <div class="rounded-xl border border-base-200 bg-base-100 p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">
              Services
            </div>
            <div class="text-2xl font-bold">{@total}</div>
            <div class="text-xs text-base-content/50">{@active_label}</div>
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

      <div class="rounded-xl border border-base-200 bg-base-100 p-4">
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

      <div class="rounded-xl border border-base-200 bg-base-100 p-4">
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

    <div class="mt-2 text-xs text-base-content/50">
      Showing {max(@check_count, @total)} plugin checks sampled.
    </div>
    """
  end

  attr :cards, :any, required: true

  defp service_card_grid(assigns) do
    ~H"""
    <div
      id="service-cards"
      phx-update="stream"
      class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4"
    >
      <div :for={{id, card} <- @cards} id={id}>
        <.service_card card={card} />
      </div>
    </div>
    """
  end

  attr :card, :map, required: true

  defp service_card(assigns) do
    ~H"""
    <.link
      navigate={@card.path}
      class={[
        "group block h-full rounded-2xl border border-base-200 bg-base-100",
        "p-4 transition hover:-translate-y-0.5 hover:shadow-md"
      ]}
    >
      <div class="flex items-center justify-between">
        <div class="text-[11px] uppercase tracking-wider text-base-content/50">
          {@card.type || "Service"}
        </div>
        <.status_badge available={@card.available} />
      </div>

      <div class="mt-2 text-lg font-semibold tracking-tight">
        {@card.name || "Service"}
      </div>

      <div class="mt-1 text-xs text-base-content/60 line-clamp-2">
        {@card.summary || "—"}
      </div>

      <div class="mt-3 flex flex-wrap items-center gap-2 text-[11px] text-base-content/50">
        <span>{@card.timestamp || "—"}</span>
        <span class="text-base-content/30">•</span>
        <span>Agent {@card.agent_id || "—"}</span>
      </div>

      <div :if={@card.display != []} class="mt-4 space-y-3">
        <%= for instruction <- @card.display do %>
          {render_compact_widget(instruction)}
        <% end %>
      </div>
    </.link>
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

  defp service_timestamp_sort_key(svc) do
    case parse_timestamp(Map.get(svc, "timestamp")) do
      {:ok, dt} -> {1, DateTime.to_unix(dt, :nanosecond)}
      _ -> {0, 0}
    end
  end

  defp latest_timestamp(services) do
    Enum.reduce(services, nil, &latest_timestamp_for_service/2)
  end

  defp latest_timestamp_for_service(%{} = svc, acc) do
    case parse_timestamp(Map.get(svc, "timestamp")) do
      {:ok, dt} -> max_datetime(dt, acc)
      _ -> acc
    end
  end

  defp latest_timestamp_for_service(_, acc), do: acc

  defp max_datetime(dt, nil), do: dt

  defp max_datetime(dt, current) do
    if DateTime.compare(dt, current) == :gt, do: dt, else: current
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

  defp filter_recent_states(states) when is_list(states) do
    cutoff = DateTime.add(DateTime.utc_now(), -@active_state_window_ms, :millisecond)

    Enum.filter(states, fn
      %ServiceState{last_observed_at: %DateTime{} = observed_at} ->
        DateTime.compare(observed_at, cutoff) != :lt

      _ ->
        false
    end)
  end

  defp filter_recent_states(_), do: []

  defp filter_service_states(states) when is_list(states) do
    Enum.reject(states, fn
      %ServiceState{service_type: service_type} ->
        service_type != "plugin"

      _ ->
        true
    end)
  end

  defp filter_service_states(_), do: []

  defp dedupe_states(states) when is_list(states) do
    states
    |> Enum.filter(&match?(%ServiceState{}, &1))
    |> Enum.sort_by(&state_sort_key/1, :desc)
    |> Enum.reduce(%{}, fn state, acc ->
      Map.put_new(acc, state_identity_key(state), state)
    end)
    |> Map.values()
  end

  defp dedupe_states(_), do: []

  defp state_sort_key(%ServiceState{last_observed_at: %DateTime{} = observed_at}),
    do: {1, DateTime.to_unix(observed_at, :nanosecond)}

  defp state_sort_key(_), do: {0, 0}

  defp state_identity_key(%ServiceState{} = state) do
    agent_id = state.agent_id || ""
    partition = state.partition || ""
    service_type = state.service_type || ""
    service_name = state.service_name || ""

    "#{agent_id}:#{partition}:#{service_type}:#{service_name}"
  end

  defp load_summary(socket) do
    scope = get_scope(socket)

    case load_active_states(scope) do
      {:ok, states} when is_list(states) ->
        states
        |> filter_recent_states()
        |> filter_service_states()
        |> dedupe_states()
        |> compute_state_summary()

      _ ->
        compute_summary(filter_plugin_services(socket.assigns.services))
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
    params = ensure_default_query(params)
    uri = Map.get(socket.assigns, :srql, %{}) |> Map.get(:page_path) || "/services"

    socket =
      socket
      |> SRQLPage.load_list(params, uri, :services,
        default_limit: @default_limit,
        max_limit: @max_limit
      )
      |> assign(:params, params)

    summary = load_summary(socket)
    cards = build_service_cards(socket.assigns.services, socket.assigns.current_scope)

    socket
    |> assign(:summary, summary)
    |> stream(:service_cards, cards, reset: true)
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

  defp service_details_path(svc) do
    ~p"/services/check?#{service_details_params(svc)}"
  end

  defp service_details_params(%{} = svc) do
    params = %{
      "service_id" => safe_param_value(Map.get(svc, "service_id") || Map.get(svc, "uid")),
      "timestamp" => safe_param_value(Map.get(svc, "timestamp")),
      "service_name" => safe_param_value(service_name_value(svc)),
      "service_type" => safe_param_value(service_type_value(svc)),
      "gateway_id" => safe_param_value(Map.get(svc, "gateway_id")),
      "agent_id" => safe_param_value(Map.get(svc, "agent_id")),
      "partition" => safe_param_value(Map.get(svc, "partition"))
    }

    params
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  # Extract scope from socket for Ash policy enforcement (includes actor)
  defp get_scope(socket) do
    Map.get(socket.assigns, :current_scope)
  end

  defp safe_param_value(nil), do: nil

  defp safe_param_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: nil
  end

  defp safe_param_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp safe_param_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp safe_param_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp safe_param_value(value), do: value |> to_string() |> safe_param_value()

  defp ensure_default_query(params) when is_map(params) do
    case Map.get(params, "q") do
      nil -> Map.put(params, "q", @default_query)
      "" -> Map.put(params, "q", @default_query)
      value when is_binary(value) -> params
      _ -> Map.put(params, "q", @default_query)
    end
  end

  defp ensure_default_query(_params), do: %{"q" => @default_query}

  defp build_service_cards(services, scope) when is_list(services) do
    services
    |> filter_plugin_services()
    |> dedupe_services()
    |> Enum.sort_by(&service_sort_key/1)
    |> Enum.map(&build_service_card(&1, scope))
  end

  defp build_service_cards(_services, _scope), do: []

  defp build_service_card(%{} = svc, scope) do
    details = parse_service_details(svc)

    display =
      details
      |> extract_display_instructions()
      |> filter_display_by_contract(details, scope)
      |> compact_display()

    %{
      id: card_dom_id(svc),
      name: service_name_value(svc),
      type: service_type_value(svc),
      available: normalize_available(Map.get(svc, "available")),
      timestamp: format_timestamp(svc),
      summary: service_summary(svc, details),
      path: service_details_path(svc),
      display: display,
      agent_id: Map.get(svc, "agent_id")
    }
  end

  defp build_service_card(_svc, _scope), do: %{}

  defp service_sort_key(svc) do
    availability = normalize_available(Map.get(svc, "available"))
    timestamp_key = service_timestamp_sort_key(svc)

    avail_sort =
      case availability do
        false -> 0
        true -> 1
        _ -> 2
      end

    {avail_sort, -elem(timestamp_key, 1)}
  end

  defp card_dom_id(svc) when is_map(svc) do
    identity = service_identity_key(svc)
    hash = :erlang.phash2(identity)
    "service-card-#{hash}"
  end

  defp card_dom_id(_), do: "service-card-unknown"

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

  defp filter_display_by_contract(display, details, scope)
       when is_list(display) and is_map(details) do
    plugin_id = get_in(details, ["labels", "plugin_id"]) || get_in(details, [:labels, :plugin_id])

    if is_binary(plugin_id) and plugin_id != "" do
      contract =
        Packages.list(%{"plugin_id" => plugin_id, "status" => "approved", "limit" => 1},
          scope: scope
        )
        |> List.first()
        |> case do
          %{display_contract: contract} when is_map(contract) -> contract
          _ -> %{}
        end

      apply_display_contract(display, contract)
    else
      display
    end
  end

  defp filter_display_by_contract(display, _details, _scope), do: display

  defp apply_display_contract(display, contract) when is_list(display) and is_map(contract) do
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

  defp apply_display_contract(display, _contract), do: display

  defp compact_display(display) when is_list(display) do
    display
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_keys/1)
    |> Enum.filter(fn item -> Map.get(item, "widget") in ["stat_card", "sparkline"] end)
    |> Enum.take(2)
  end

  defp compact_display(_), do: []

  defp service_summary(service, details) do
    Map.get(details, "summary") || Map.get(service, "message")
  end

  defp filter_plugin_services(services) when is_list(services) do
    Enum.filter(services, fn svc ->
      service_type_value(svc) == "plugin"
    end)
  end

  defp filter_plugin_services(_), do: []

  defp render_compact_widget(%{"widget" => "stat_card"} = data) do
    label = Map.get(data, "label") || "Value"
    value = Map.get(data, "value") || "—"
    tone = Map.get(data, "tone") || Map.get(data, "color") || "neutral"
    assigns = %{label: label, value: value, tone: tone}

    ~H"""
    <div class="rounded-lg border border-base-200/60 bg-base-200/40 p-3">
      <div class="text-[11px] text-base-content/60">{@label}</div>
      <div class={stat_value_class(@tone)}>{@value}</div>
    </div>
    """
  end

  defp render_compact_widget(%{"widget" => "sparkline"} = data) do
    points = sparkline_points(Map.get(data, "data"))
    label = Map.get(data, "label") || "Trend"
    assigns = %{points: points, label: label}

    ~H"""
    <div class="rounded-lg border border-base-200/60 bg-base-200/40 p-3">
      <div class="text-[11px] text-base-content/60 mb-2">{@label}</div>
      <svg viewBox="0 0 100 32" class="w-full h-8 text-primary">
        <polyline fill="none" stroke="currentColor" stroke-width="2" points={@points} />
      </svg>
    </div>
    """
  end

  defp render_compact_widget(_), do: nil

  defp sparkline_points(values) when is_list(values) and values != [] do
    numbers =
      values
      |> Enum.map(&to_float/1)
      |> Enum.reject(&is_nil/1)

    case numbers do
      [] ->
        ""

      _ ->
        min = Enum.min(numbers)
        max = Enum.max(numbers)
        range = if max - min == 0, do: 1.0, else: max - min
        step = 100 / max(Enum.count(numbers) - 1, 1)

        numbers
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {value, idx} ->
          x = idx * step
          y = 32 - (value - min) / range * 28 - 2
          "#{Float.round(x, 2)},#{Float.round(y, 2)}"
        end)
    end
  end

  defp sparkline_points(_), do: ""

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {num, ""} -> num
      _ -> nil
    end
  end

  defp to_float(_), do: nil

  defp stat_value_class(tone) do
    base = "text-lg font-semibold"

    case tone do
      "success" -> [base, "text-success"]
      "warning" -> [base, "text-warning"]
      "error" -> [base, "text-error"]
      "info" -> [base, "text-info"]
      _ -> [base, "text-base-content"]
    end
  end

  defp stringify_keys(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_keys(value)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
