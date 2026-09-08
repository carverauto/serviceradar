defmodule ServiceRadarWebNGWeb.ServiceLive.Index.Data do
  @moduledoc false

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadarWebNGWeb.ServiceLive.Display
  alias ServiceRadarWebNGWeb.ServiceLive.Service

  def reconcile_plugin_assignments do
    ServiceStateRegistry.reconcile_plugin_assignments()
  end

  def ensure_default_query(params, default_query) when is_map(params) do
    case Map.get(params, "q") do
      nil -> Map.put(params, "q", default_query)
      "" -> Map.put(params, "q", default_query)
      value when is_binary(value) -> params
      _ -> Map.put(params, "q", default_query)
    end
  end

  def ensure_default_query(_params, default_query), do: %{"q" => default_query}

  def load_plugin_states(scope) do
    ServiceState
    |> Ash.Query.for_read(:active_plugin_cards, %{})
    |> Ash.read(scope: scope)
    |> case do
      {:ok, states} when is_list(states) -> dedupe_states(states)
      _ -> []
    end
  end

  def summary(plugin_states, _services) when is_list(plugin_states) and plugin_states != [] do
    compute_state_summary(plugin_states)
  end

  def summary(_plugin_states, services) do
    services
    |> filter_plugin_services()
    |> compute_summary()
  end

  def cards(plugin_states, _services, scope) when is_list(plugin_states) and plugin_states != [] do
    plugin_states
    |> Enum.map(&service_state_to_service/1)
    |> build_cards(scope)
  end

  def cards(_plugin_states, services, scope) when is_list(services) do
    build_cards(services, scope)
  end

  def cards(_plugin_states, _services, _scope), do: []

  defp dedupe_states(states) do
    states
    |> Enum.filter(&match?(%ServiceState{}, &1))
    |> Enum.sort_by(&state_sort_key/1, :desc)
    |> Enum.reduce(%{}, fn state, acc ->
      Map.put_new(acc, state_identity_key(state), state)
    end)
    |> Map.values()
  end

  defp state_sort_key(%ServiceState{} = state), do: PluginStateContract.state_rank(state)

  defp state_identity_key(%ServiceState{} = state) do
    agent_id = state.agent_id || ""
    partition = state.partition || ""
    service_type = state.service_type || ""
    service_name = state.service_name || ""

    "#{agent_id}:#{partition}:#{service_type}:#{service_name}"
  end

  defp compute_summary(services) when is_list(services) do
    unique_services = dedupe_services(services)
    initial = base_summary(length(services), latest_timestamp(services))
    Enum.reduce(unique_services, initial, &accumulate_service/2)
  end

  defp compute_state_summary(states) do
    initial = base_summary(length(states), latest_state_timestamp(states))

    Enum.reduce(states, initial, fn state, acc ->
      available? = state.available == true
      check_name = normalize_service_name(state.service_name)

      %{
        acc
        | total: acc.total + 1,
          available: acc.available + if(available?, do: 1, else: 0),
          unavailable: acc.unavailable + if(available?, do: 0, else: 1),
          by_check: update_by_check(acc.by_check, check_name, available?)
      }
    end)
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

  defp accumulate_service(service, acc) do
    available? = Service.normalize_available(Map.get(service, "available")) == true
    check_name = normalize_service_name(Service.name(service))

    %{
      acc
      | total: acc.total + 1,
        available: acc.available + if(available?, do: 1, else: 0),
        unavailable: acc.unavailable + if(available?, do: 0, else: 1),
        by_check: update_by_check(acc.by_check, check_name, available?)
    }
  end

  defp normalize_service_name(nil), do: "unknown"
  defp normalize_service_name(""), do: "unknown"
  defp normalize_service_name(value), do: value |> to_string() |> String.trim()

  defp update_by_check(by_check, check_name, available?) do
    Map.update(by_check, check_name, %{available: 0, unavailable: 0}, fn counts ->
      if available? do
        Map.update!(counts, :available, &(&1 + 1))
      else
        Map.update!(counts, :unavailable, &(&1 + 1))
      end
    end)
  end

  defp latest_state_timestamp(states) do
    Enum.reduce(states, nil, fn
      %ServiceState{last_observed_at: %DateTime{} = datetime}, nil ->
        datetime

      %ServiceState{last_observed_at: %DateTime{} = datetime}, current ->
        max_datetime(datetime, current)

      _, current ->
        current
    end)
  end

  defp latest_timestamp(services) do
    Enum.reduce(services, nil, fn
      %{} = service, current ->
        case Service.parse_iso_timestamp(Map.get(service, "timestamp")) do
          {:ok, datetime} -> max_datetime(datetime, current)
          _ -> current
        end

      _, current ->
        current
    end)
  end

  defp max_datetime(datetime, nil), do: datetime

  defp max_datetime(datetime, current) do
    if DateTime.after?(datetime, current), do: datetime, else: current
  end

  defp build_cards(services, scope) do
    services =
      services
      |> filter_plugin_services()
      |> dedupe_services()
      |> Enum.sort_by(&service_sort_key/1)

    services_with_details = Enum.map(services, &{&1, Service.parse_details(&1)})

    contracts =
      services_with_details
      |> Enum.map(&elem(&1, 1))
      |> Display.contracts_by_plugin_id(scope)

    Enum.map(services_with_details, fn {service, details} ->
      build_card(service, details, contracts)
    end)
  end

  defp build_card(service, details, contracts) do
    details = if is_map(details), do: details, else: %{}

    display =
      details
      |> Service.display_instructions()
      |> Display.filter_card_display(details, contracts)
      |> compact_display()

    %{
      id: card_dom_id(service),
      name: Service.name(service),
      type: Service.type(service),
      available: Service.normalize_available(Map.get(service, "available")),
      timestamp: Service.timestamp(service),
      timestamp_fallback: Service.timestamp_fallback(service),
      summary: Service.summary(service, details),
      path: Service.details_path(service),
      display: display,
      agent_id: Map.get(service, "agent_id")
    }
  end

  defp dedupe_services(services) do
    services
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&service_timestamp_sort_key/1, :desc)
    |> Enum.reduce(%{}, fn service, acc ->
      Map.put_new(acc, service_identity_key(service), service)
    end)
    |> Map.values()
  end

  defp service_identity_key(service) do
    agent_id = Map.get(service, "agent_id") || ""
    partition = Map.get(service, "partition") || Map.get(service, "partition_id") || ""
    service_type = Service.type(service) || ""
    service_name = Service.name(service) || ""

    "#{agent_id}:#{partition}:#{service_type}:#{service_name}"
  end

  defp service_timestamp_sort_key(service) do
    case Service.parse_iso_timestamp(Map.get(service, "timestamp")) do
      {:ok, datetime} -> {1, DateTime.to_unix(datetime, :nanosecond)}
      _ -> {0, 0}
    end
  end

  defp service_sort_key(service) do
    availability = Service.normalize_available(Map.get(service, "available"))
    {_valid, timestamp} = service_timestamp_sort_key(service)

    availability_rank =
      case availability do
        false -> 0
        true -> 1
        _ -> 2
      end

    {availability_rank, -timestamp}
  end

  defp card_dom_id(service) do
    "service-card-#{:erlang.phash2(service_identity_key(service))}"
  end

  defp filter_plugin_services(services) when is_list(services) do
    Enum.filter(services, &(Service.type(&1) == "plugin"))
  end

  defp filter_plugin_services(_services), do: []

  defp service_state_to_service(%ServiceState{} = state) do
    %{
      "service_id" => loaded_field(state, :id),
      "service_name" => loaded_field(state, :service_name),
      "service_type" => loaded_field(state, :service_type),
      "available" => loaded_field(state, :available),
      "message" => loaded_field(state, :message),
      "timestamp" => timestamp_to_iso8601(loaded_field(state, :last_observed_at)),
      "gateway_id" => loaded_field(state, :gateway_id),
      "agent_id" => loaded_field(state, :agent_id),
      "partition" => loaded_field(state, :partition)
    }
  end

  defp loaded_field(%ServiceState{} = state, field) do
    case Map.get(state, field) do
      %Ash.NotLoaded{} -> nil
      value -> value
    end
  end

  defp timestamp_to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_to_iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp_to_iso8601(_value), do: nil

  defp compact_display(display) when is_list(display) do
    display
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_keys/1)
    |> Enum.filter(&(Map.get(&1, "widget") in ["stat_card", "sparkline"]))
    |> Enum.take(2)
  end

  defp compact_display(_display), do: []

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
