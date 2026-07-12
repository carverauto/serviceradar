defmodule ServiceRadarWebNGWeb.ServiceLive.Show.History do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias ServiceRadarWebNGWeb.ServiceLive.Service
  alias ServiceRadarWebNGWeb.ServiceLive.Show.Query
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  def load(socket, query, uri, params, limit) do
    previous_history = socket.assigns.history
    srql_params = %{"q" => query, "limit" => Integer.to_string(limit)}

    socket =
      SRQLPage.load_list(socket, srql_params, uri, :history,
        default_limit: limit,
        max_limit: limit
      )

    history =
      if get_in(socket.assigns, [:srql, :error]) && previous_history != [] do
        previous_history
      else
        socket.assigns.history
      end

    assign(socket, :history, maybe_expand(history, params, socket.assigns.current_scope, limit))
  end

  def apply_status(socket, status, limit) do
    if matches_current_service?(status, socket.assigns.service) do
      {:matched, append(socket, status, limit)}
    else
      {:ignored, socket}
    end
  end

  defp maybe_expand(history, params, scope, limit) do
    if length(history) >= limit do
      history
    else
      case Query.fallback(params, limit) do
        nil -> history
        query -> merge(history, fetch(query, scope, limit), limit)
      end
    end
  end

  defp fetch(query, scope, limit) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)

    case srql_module.query(query, %{limit: limit, scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) -> results
      _ -> []
    end
  end

  defp merge(primary, fallback, limit) do
    primary
    |> Enum.concat(fallback)
    |> Enum.uniq_by(&history_key/1)
    |> Enum.sort_by(&history_sort_key/1, :desc)
    |> Enum.take(limit)
  end

  defp append(socket, status, limit) do
    history = socket.assigns.history
    normalized = normalize_status_map(status)
    key = history_key(normalized)

    history =
      if Enum.any?(history, &(history_key(&1) == key)) do
        history
      else
        Enum.take([normalized | history], limit)
      end

    assign(socket, :history, history)
  end

  defp history_key(%{} = service) do
    {
      Map.get(service, "timestamp"),
      Map.get(service, "gateway_id"),
      Service.name(service)
    }
  end

  defp history_sort_key(%{} = service) do
    case Query.parse_datetime(Map.get(service, "timestamp")) do
      {:ok, datetime} -> DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp normalize_status_map(status) when is_map(status) do
    map =
      Enum.reduce(status, %{}, fn {key, value}, acc ->
        string_key = if is_atom(key), do: Atom.to_string(key), else: to_string(key)
        Map.put(acc, string_key, normalize_status_value(value))
      end)

    Map.put(map, "message", normalize_status_message(map))
  end

  defp normalize_status_map(status), do: %{"message" => to_string(status)}

  defp normalize_status_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_status_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_status_value(value), do: value

  defp normalize_status_message(map) do
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

  defp service_id_match?(status, service) do
    status_service_id = fetch_status_value(status, :service_id)
    service_id = Map.get(service, "service_id") || Map.get(service, "uid")

    is_binary(status_service_id) and status_service_id != "" and
      is_binary(service_id) and service_id != "" and status_service_id == service_id
  end

  defp identity_match?(status, service) do
    fetch_status_value(status, :service_name) == Service.name(service) and
      fetch_status_value(status, :service_type) == Service.type(service) and
      fetch_status_value(status, :gateway_id) == Map.get(service, "gateway_id") and
      fetch_status_value(status, :agent_id) == Map.get(service, "agent_id") and
      normalize_partition(fetch_status_value(status, :partition), status) ==
        normalize_partition(Map.get(service, "partition"), service)
  end

  defp fetch_status_value(status, key) when is_map(status) do
    Map.get(status, key) || Map.get(status, Atom.to_string(key))
  end

  defp normalize_partition(value, status_or_service) do
    value || fetch_status_value(status_or_service, :partition_id) || "default"
  end
end
