defmodule ServiceRadarWebNGWeb.DeviceLive.AvailabilityData do
  @moduledoc false

  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadarWebNGWeb.DeviceLive.ICMPData

  @bucket_seconds 30 * 60
  @window_seconds 24 * 60 * 60

  def load_availability(srql_module, device_uid, scope, opts \\ []) do
    # Resolve the range once so all source queries and displayed gaps share it.
    now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.truncate(:second)
    start_at = DateTime.add(now, -@window_seconds, :second)
    range = "[#{DateTime.to_iso8601(start_at)},#{DateTime.to_iso8601(now)}]"

    case ICMPData.load_availability(srql_module, [device_uid], scope,
           time_range: range,
           bucket: "30m",
           limit: 100
         ) do
      {:ok, rows} -> build_availability(rows, start_at, now)
      {:error, _reason} -> nil
    end
  end

  defp build_availability(rows, start_at, end_at) do
    first_second = DateTime.to_unix(start_at)
    last_second = DateTime.to_unix(end_at)
    first_bucket = bucket_start(first_second)
    last_bucket = bucket_start(last_second - 1)

    statuses =
      Enum.reduce(rows, %{}, fn row, acc ->
        with {:ok, timestamp} <- parse_timestamp(row["timestamp"]),
             second = timestamp |> DateTime.to_unix() |> bucket_start(),
             true <- second >= first_bucket and second <= last_bucket,
             value when value in [0, 0.0, 1, 1.0] <- row["value"] do
          # Duplicate samples in a bucket never hide an observed failure.
          Map.update(acc, second, value, &min(&1, value))
        else
          _ -> acc
        end
      end)

    segments =
      Enum.map(first_bucket..last_bucket//@bucket_seconds, fn second ->
        from = max(second, first_second)
        until = min(second + @bucket_seconds, last_second)
        state = status(Map.get(statuses, second))
        timestamp = second |> DateTime.from_unix!() |> DateTime.to_iso8601()

        %{
          timestamp: timestamp,
          status: state,
          available: state == :online,
          width: (until - from) / @window_seconds * 100.0,
          title: status_label(state)
        }
      end)

    online = Enum.count(segments, &(&1.status == :online))
    offline = Enum.count(segments, &(&1.status == :offline))
    observed = online + offline

    %{
      uptime_pct: if(observed > 0, do: Float.round(online / observed * 100.0, 1)),
      total_checks: observed,
      online_checks: online,
      offline_checks: offline,
      unknown_checks: length(segments) - observed,
      bucket_count: length(segments),
      window_start: start_at,
      window_end: end_at,
      segments: segments
    }
  end

  defp bucket_start(second), do: Integer.floor_div(second, @bucket_seconds) * @bucket_seconds
  defp status(value) when value in [1, 1.0], do: :online
  defp status(value) when value in [0, 0.0], do: :offline
  defp status(_), do: :unknown
  defp status_label(:online), do: "Online"
  defp status_label(:offline), do: "Offline (failure observed)"
  defp status_label(:unknown), do: "Unknown (no observations)"

  defp parse_timestamp(%DateTime{} = value), do: {:ok, value}

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_timestamp(_), do: :error

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  def load_agent_availability(_scope, nil), do: []

  def load_agent_availability(scope, device_uid) when is_binary(device_uid) do
    query = Ash.Query.for_read(DeviceAgentAvailability, :by_device, %{device_uid: device_uid})

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) -> rows
      _ -> []
    end
  end

  def load_agent_availability(_scope, _device_uid), do: []

  def load_healthcheck_summary(srql_module, device_uid, scope) do
    case service_query_for_device(device_uid) do
      {:ok, query} -> query_service_summary(srql_module, query, scope)
      :error -> nil
    end
  end

  defp service_query_for_device(device_uid) do
    case parse_service_device_uid(device_uid) do
      {:service, "checker", checker_id} ->
        service_query_for_checker(checker_id)

      {:service, "agent", agent_id} ->
        {:ok, service_query(%{"agent_id" => agent_id})}

      {:service, "gateway", gateway_id} ->
        {:ok, service_query(%{"gateway_id" => gateway_id})}

      {:service, _service_type, service_id} ->
        {:ok, service_query(%{"service_name" => service_id})}

      _ ->
        :error
    end
  end

  defp service_query_for_checker(checker_id) do
    case parse_checker_identity(checker_id) do
      {:ok, service_name, agent_id} ->
        {:ok, service_query(%{"service_name" => service_name, "agent_id" => agent_id})}

      :error ->
        :error
    end
  end

  defp service_query(filters) do
    filter_expr =
      Enum.map_join(filters, " ", fn {field, value} -> "#{field}:\"#{escape_value(value)}\"" end)

    "in:services " <> filter_expr <> " time:last_24h sort:timestamp:desc limit:200"
  end

  defp query_service_summary(srql_module, query, scope) do
    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
        build_healthcheck_summary(rows)

      _ ->
        nil
    end
  end

  defp parse_service_device_uid(device_uid) when is_binary(device_uid) do
    case String.split(device_uid, ":", parts: 3) do
      ["serviceradar", service_type, service_id] when service_type != "" and service_id != "" ->
        {:service, service_type, service_id}

      _ ->
        :non_service
    end
  end

  defp parse_service_device_uid(_), do: :non_service

  defp parse_checker_identity(checker_id) when is_binary(checker_id) do
    case String.split(checker_id, "@", parts: 2) do
      [service_name, agent_id] when service_name != "" and agent_id != "" ->
        {:ok, service_name, agent_id}

      _ ->
        :error
    end
  end

  defp build_healthcheck_summary(rows) do
    # Group by service_name and take most recent status for each
    services_by_name =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn row, acc ->
        service_name = Map.get(row, "service_name") || "Unknown"
        # Keep first (most recent) per service
        Map.put_new(acc, service_name, row)
      end)

    services =
      services_by_name
      |> Map.values()
      |> Enum.map(fn row ->
        %{
          service_name: Map.get(row, "service_name") || "Unknown",
          service_type: Map.get(row, "service_type") || "",
          available: Map.get(row, "available") == true,
          message: Map.get(row, "message") || "",
          timestamp: Map.get(row, "timestamp") || ""
        }
      end)
      |> Enum.sort_by(fn s -> {s.available, s.service_name} end)

    available_count = Enum.count(services, & &1.available)
    unavailable_count = length(services) - available_count

    %{
      services: services,
      total: length(services),
      available: available_count,
      unavailable: unavailable_count
    }
  end
end
