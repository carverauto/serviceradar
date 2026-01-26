defmodule ServiceRadarWebNGWeb.ServiceLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents
  import ServiceRadarWebNGWeb.PluginResults

  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias Phoenix.LiveView.JS

  @default_limit 200
  @history_per_page 20
  @refresh_debounce_ms 750

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ServiceStatusPubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Service Check")
     |> assign(:service, nil)
     |> assign(:details, %{})
     |> assign(:display, [])
     |> assign(:display_contract, %{})
     |> assign(:schema_version, nil)
     |> assign(:query, "")
     |> assign(:history, [])
     |> assign(:history_page, 1)
     |> assign(:history_per_page, @history_per_page)
     |> assign(:limit, @default_limit)
     |> assign(:refresh_pending, false)
     |> SRQLPage.init("services", default_limit: @default_limit, builder_available: false)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    query = Map.get(params, "q") |> normalize_query() || build_query(params)
    socket =
      socket
      |> assign(:query, query)
      |> assign(:history_page, 1)
      |> load_history(query, uri, params)

    service = pick_service(socket.assigns.history, params)

    {details, display, contract, schema_version} =
      build_display(service, socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:service, service)
     |> assign(:details, details)
     |> assign(:display, display)
     |> assign(:display_contract, contract)
     |> assign(:schema_version, schema_version)}
  end

  @impl true
  def handle_info({:service_status_updated, status}, socket) do
    {:noreply,
     if matches_current_service?(status, socket.assigns.service) do
       socket = append_history(socket, status)
       schedule_refresh(socket)
     else
       socket
     end}
  end

  def handle_info(:refresh_service_details, socket) do
    {:noreply, refresh_service_details(socket)}
  end

  @impl true
  def handle_event("history_page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    {:noreply, assign(socket, :history_page, page)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-5xl p-6">
        <div class="space-y-4">
          <.ui_panel>
            <:header>
              <div class="flex items-start justify-between gap-3">
                <div>
                  <div class="text-sm font-semibold">Service Check Details</div>
                  <div class="text-xs text-base-content/70">
                    <span :if={@service}>
                      {service_name_value(@service) || "Service"}
                    </span>
                    <span :if={!@service}>No matching service check found.</span>
                  </div>
                </div>
                <.link navigate={~p"/services"} class="btn btn-ghost btn-xs">Back to services</.link>
              </div>
            </:header>

            <div :if={!@service} class="text-sm text-base-content/60">
              We could not find a matching service check for the requested time.
            </div>

            <div :if={@service} class="space-y-4">
              <div class="flex flex-wrap gap-4 text-xs text-base-content/70">
                <div>
                  <span class="font-semibold">Status:</span> {format_status(
                    service_status(@service, @details)
                  )}
                </div>
                <div>
                  <span class="font-semibold">Type:</span> {service_type_value(@service) || "—"}
                </div>
                <div>
                  <span class="font-semibold">Service:</span> {service_name_value(@service) || "—"}
                </div>
                <div>
                  <span class="font-semibold">Gateway:</span> {Map.get(@service, "gateway_id") || "—"}
                </div>
                <div>
                  <span class="font-semibold">Agent:</span> {Map.get(@service, "agent_id") || "—"}
                </div>
                <div>
                  <span class="font-semibold">Partition:</span> {Map.get(@service, "partition") || "—"}
                </div>
                <div>
                  <span class="font-semibold">Observed:</span> {Map.get(@service, "timestamp") || "—"}
                </div>
              </div>

              <div class="text-sm">{service_summary(@service, @details) || "—"}</div>

              <div :if={@schema_version} class="text-[11px] text-base-content/50">
                UI schema version {@schema_version}
              </div>

              <.plugin_results display={@display} />
            </div>
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div class="text-sm font-semibold">Service Check History</div>
            </:header>

            <.service_history_table
              services={@history}
              page={@history_page}
              per_page={@history_per_page}
            />
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp build_query(params) do
    base = ["in:services"]
    filters = build_filters(params)
    filters = if filters == [], do: ["service_type:plugin"], else: filters

    (base ++ filters ++ ["sort:timestamp:desc"] ++ ["limit:#{@default_limit}"])
    |> Enum.join(" ")
  end

  defp build_filters(params) do
    service_id = Map.get(params, "service_id") || Map.get(params, "uid")

    if is_binary(service_id) and service_id != "" do
      ["service_id:\"#{escape_srql_value(service_id)}\""]
    else
      build_identity_filters(params)
    end
  end

  defp build_identity_filters(params) do
    [:service_name, :service_type, :gateway_id, :agent_id, :partition]
    |> Enum.flat_map(&filter_param(params, &1))
  end

  defp filter_param(params, key) do
    value = Map.get(params, Atom.to_string(key))

    if is_binary(value) and value != "" do
      ["#{key}:\"#{escape_srql_value(value)}\""]
    else
      []
    end
  end

  defp normalize_query(nil), do: nil
  defp normalize_query(""), do: nil

  defp normalize_query(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_query(_), do: nil

  defp escape_srql_value(value) do
    value
    |> to_string()
    |> String.replace("\"", "\\\"")
  end

  defp pick_service(services, params) when is_list(services) do
    target = Map.get(params, "timestamp")

    case parse_datetime(target) do
      {:ok, dt} ->
        Enum.find(services, fn svc -> match_timestamp?(svc, dt) end) || List.first(services)

      _ ->
        List.first(services)
    end
  end

  defp pick_service(_services, _params), do: nil

  defp match_timestamp?(svc, %DateTime{} = target) when is_map(svc) do
    case parse_datetime(Map.get(svc, "timestamp")) do
      {:ok, dt} -> DateTime.compare(dt, target) == :eq
      _ -> false
    end
  end

  defp match_timestamp?(_svc, _target), do: false

  defp parse_datetime(value) when is_binary(value) do
    trimmed = String.trim(value)

    case DateTime.from_iso8601(trimmed) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case Integer.parse(trimmed) do
          {int, ""} -> parse_unix_timestamp(int)
          _ -> :error
        end
    end
  end

  defp parse_datetime(value) when is_integer(value) do
    parse_unix_timestamp(value)
  end

  defp parse_datetime(_), do: :error

  defp parse_unix_timestamp(value) when is_integer(value) do
    # Heuristic: 10 digits => seconds, 13+ => milliseconds/nanoseconds
    cond do
      value <= 0 ->
        :error

      value > 1_000_000_000_000_000_000 ->
        :error

      value >= 1_000_000_000_000_000 ->
        seconds = div(value, 1_000_000_000)
        nanos = rem(value, 1_000_000_000)

        DateTime.from_unix(seconds, :second)
        |> case do
          {:ok, dt} -> {:ok, %{dt | microsecond: {div(nanos, 1000), 6}}}
          error -> error
        end

      value >= 1_000_000_000_000 ->
        DateTime.from_unix(div(value, 1000), :millisecond)

      value > 1_000_000_000 ->
        DateTime.from_unix(value, :second)

      true ->
        DateTime.from_unix(value, :second)
    end
  end

  defp build_display(service, scope) when is_map(service) do
    details = parse_service_details(service)
    contract = load_display_contract(details, scope)

    display =
      details
      |> extract_display_instructions()
      |> filter_display_by_contract(contract)

    {details, display, contract, resolve_schema_version(details, contract)}
  end

  defp build_display(_service, _scope), do: {%{}, [], %{}, nil}

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

  defp service_name_value(%{} = svc) do
    Map.get(svc, "service_name") ||
      Map.get(svc, "name") ||
      Map.get(svc, "service") ||
      Map.get(svc, "check_name")
  end

  defp service_name_value(_), do: nil

  defp service_type_value(%{} = svc) do
    Map.get(svc, "service_type") ||
      Map.get(svc, "type") ||
      Map.get(svc, "check_type") ||
      Map.get(svc, "service_kind")
  end

  defp service_type_value(_), do: nil

  defp service_status(service, details) do
    Map.get(details, "status") || Map.get(service, "status")
  end

  defp service_summary(service, details) do
    Map.get(details, "summary") || Map.get(service, "message")
  end

  defp format_status(status) do
    status
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "—"
      value -> value
    end
  end

  attr :services, :list, default: []
  attr :page, :integer, default: 1
  attr :per_page, :integer, default: 20

  defp service_history_table(assigns) do
    total = length(assigns.services)
    total_pages = max(1, ceil(total / assigns.per_page))
    page = min(assigns.page, total_pages)
    start_idx = (page - 1) * assigns.per_page
    page_services = Enum.slice(assigns.services, start_idx, assigns.per_page)

    assigns =
      assigns
      |> assign(:page_services, page_services)
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

          <%= for {svc, idx} <- Enum.with_index(@page_services) do %>
            <% path = service_details_path(svc) %>
            <tr
              id={"service-history-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer"
              phx-click={JS.navigate(path)}
            >
              <td class="whitespace-nowrap text-xs font-mono">
                {format_timestamp(svc)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.status_badge available={Map.get(svc, "available")} />
              </td>
              <td class="text-xs truncate max-w-[32rem]" title={history_message(svc)}>
                {history_message(svc)}
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

  defp format_timestamp(svc) do
    ts = Map.get(svc, "timestamp")

    case parse_datetime(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp history_message(%{} = svc) do
    details = parse_service_details(svc)
    service_summary(svc, details) || Map.get(svc, "message") || "—"
  end

  defp history_message(_), do: "—"

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

  defp safe_param_value(nil), do: nil

  defp safe_param_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: nil
  end

  defp safe_param_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp safe_param_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp safe_param_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp safe_param_value(value), do: value |> to_string() |> safe_param_value()

  defp schedule_refresh(socket) do
    if socket.assigns.refresh_pending do
      socket
    else
      Process.send_after(self(), :refresh_service_details, @refresh_debounce_ms)
      assign(socket, :refresh_pending, true)
    end
  end

  defp refresh_service_details(socket) do
    query = socket.assigns.query || build_query(%{})
    uri = socket.assigns.srql[:page_path] || "/services/check"

    socket = load_history(socket, query, uri, %{})

    lookup_params =
      case socket.assigns.service do
        %{} = svc -> service_details_params(svc)
        _ -> %{}
      end

    service = pick_service(socket.assigns.history, lookup_params)

    {details, display, contract, schema_version} =
      build_display(service, socket.assigns.current_scope)

    socket
    |> assign(:service, service)
    |> assign(:details, details)
    |> assign(:display, display)
    |> assign(:display_contract, contract)
    |> assign(:schema_version, schema_version)
    |> assign(:refresh_pending, false)
  end

  defp load_history(socket, query, uri, params) do
    prev_history = socket.assigns.history
    srql_params = %{"q" => query, "limit" => Integer.to_string(@default_limit)}

    socket =
      socket
      |> SRQLPage.load_list(srql_params, uri, :history,
        default_limit: @default_limit,
        max_limit: @default_limit
      )

    history = socket.assigns.history
    srql_error = get_in(socket.assigns, [:srql, :error])

    history =
      if srql_error && prev_history != [] do
        prev_history
      else
        history
      end

    history = maybe_expand_history(history, params, socket.assigns.current_scope)

    assign(socket, :history, history)
  end

  defp maybe_expand_history(history, params, scope) do
    if length(history) >= @default_limit do
      history
    else
      query = build_history_fallback_query(params)

      if query == nil do
        history
      else
        fallback = fetch_history(query, scope)
        merge_history(history, fallback)
      end
    end
  end

  defp fetch_history(query, scope) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)

    case srql_module.query(query, %{limit: @default_limit, scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) -> results
      _ -> []
    end
  end

  defp merge_history(primary, fallback) do
    primary
    |> Enum.concat(fallback)
    |> Enum.uniq_by(&history_key/1)
    |> Enum.sort_by(&history_sort_key/1, :desc)
    |> Enum.take(@default_limit)
  end

  defp history_key(%{} = svc) do
    {
      Map.get(svc, "timestamp"),
      Map.get(svc, "gateway_id"),
      service_name_value(svc)
    }
  end

  defp history_sort_key(%{} = svc) do
    case parse_datetime(Map.get(svc, "timestamp")) do
      {:ok, dt} -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp build_history_fallback_query(params) do
    # If the caller provided an explicit SRQL query, don't override it.
    if Map.has_key?(params, "q") do
      nil
    else
      filters = build_identity_filters(params)

      if filters == [] do
        nil
      else
        (["in:services" | filters] ++ ["sort:timestamp:desc", "limit:#{@default_limit}"])
        |> Enum.join(" ")
      end
    end
  end

  defp maybe_add_filter(filters, _key, nil), do: filters
  defp maybe_add_filter(filters, _key, ""), do: filters

  defp maybe_add_filter(filters, key, value) do
    filters ++ ["#{key}:\"#{escape_srql_value(value)}\""]
  end

  defp append_history(socket, status) do
    history = socket.assigns.history
    normalized = normalize_status_map(status)
    key = history_key(normalized)

    history =
      if Enum.any?(history, &(history_key(&1) == key)) do
        history
      else
        [normalized | history] |> Enum.take(@default_limit)
      end

    assign(socket, :history, history)
  end

  defp normalize_status_map(status) when is_map(status) do
    map =
      status
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        string_key = if is_atom(key), do: Atom.to_string(key), else: to_string(key)
        Map.put(acc, string_key, normalize_status_value(value))
      end)

    Map.put(map, "message", normalize_status_message(map))
  end

  defp normalize_status_map(status), do: %{"message" => to_string(status)}

  defp normalize_status_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_status_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_status_value(value), do: value

  defp normalize_status_message(map) when is_map(map) do
    message = Map.get(map, "message")
    summary = Map.get(map, "summary") || Map.get(map, "status")

    cond do
      is_binary(message) and message != "" -> message
      is_binary(summary) and summary != "" -> summary
      true -> "—"
    end
  end

  defp matches_current_service?(_status, nil), do: false

  defp matches_current_service?(status, service) when is_map(status) and is_map(service) do
    service_id_match?(status, service) || identity_match?(status, service)
  end

  defp matches_current_service?(_status, _service), do: false

  defp fetch_status_value(status, key) when is_map(status) do
    Map.get(status, key) || Map.get(status, Atom.to_string(key))
  end

  defp service_id_match?(status, service) do
    status_service_id = fetch_status_value(status, :service_id)
    service_id = Map.get(service, "service_id") || Map.get(service, "uid")

    if is_binary(status_service_id) and status_service_id != "" and
         is_binary(service_id) and service_id != "" do
      status_service_id == service_id
    else
      false
    end
  end

  defp identity_match?(status, service) do
    fetch_status_value(status, :service_name) == service_name_value(service) and
      fetch_status_value(status, :service_type) == service_type_value(service) and
      fetch_status_value(status, :gateway_id) == Map.get(service, "gateway_id") and
      fetch_status_value(status, :agent_id) == Map.get(service, "agent_id") and
      normalize_partition(fetch_status_value(status, :partition), status) ==
        normalize_partition(Map.get(service, "partition"), service)
  end

  defp normalize_partition(value, status_or_service) do
    value ||
      fetch_status_value(status_or_service, :partition_id) ||
      "default"
  end
end
