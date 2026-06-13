defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DeviceLive.QueryData

  require Logger

  @metric_classes ~w(cpu memory disk interface red)
  @anomaly_limit 50
  @capacity_limit 25

  def empty(status \\ :ok) do
    %{
      status: status,
      anomaly_rows: [],
      capacity_rows: [],
      anomaly_query: nil,
      capacity_query: nil,
      anomaly_filter: nil,
      capacity_filter: nil,
      anomaly_error: nil,
      capacity_error: nil,
      metric_statuses: metric_statuses([])
    }
  end

  def load(_srql_module, identity, _scope) when identity in [nil, %{}], do: empty()

  def load(srql_module, identity, scope) when is_map(identity) do
    candidates = filter_candidates(identity)

    if candidates == [] do
      empty()
    else
      anomaly = load_first(srql_module, candidates, scope, &anomaly_query/1)
      capacity = load_first(srql_module, capacity_candidates(candidates), scope, &capacity_query/1)

      %{
        status: combined_status(anomaly, capacity),
        anomaly_rows: anomaly.rows,
        capacity_rows: capacity.rows,
        anomaly_query: anomaly.query,
        capacity_query: capacity.query,
        anomaly_filter: anomaly.filter,
        capacity_filter: capacity.filter,
        anomaly_error: anomaly.error,
        capacity_error: capacity.error,
        metric_statuses: metric_statuses(anomaly.rows)
      }
    end
  end

  defp load_first(srql_module, candidates, scope, query_fun) do
    candidates
    |> Enum.reduce_while(nil, fn candidate, acc ->
      query = query_fun.(candidate)

      case srql_module.query(query, %{scope: scope}) do
        {:ok, %{"results" => rows}} when is_list(rows) ->
          result = %{
            rows: Enum.filter(rows, &is_map/1),
            query: query,
            filter: Map.take(candidate, [:field, :label, :value]),
            error: nil,
            status: :ok
          }

          if result.rows == [] do
            {:cont, acc || result}
          else
            {:halt, result}
          end

        {:ok, other} ->
          error = "unexpected SRQL response: #{inspect(other)}"
          Logger.warning("Unexpected device anomaly/capacity SRQL response for #{query}: #{error}")
          {:cont, acc || error_result(candidate, query, error)}

        {:error, reason} ->
          error = "SRQL error: #{QueryData.format_error(reason)}"
          Logger.warning("Failed device anomaly/capacity SRQL query #{query}: #{error}")
          {:cont, acc || error_result(candidate, query, error)}
      end
    end)
    |> case do
      nil -> %{rows: [], query: nil, filter: nil, error: nil, status: :ok}
      result -> result
    end
  end

  defp error_result(candidate, query, error) do
    %{
      rows: [],
      query: query,
      filter: Map.take(candidate, [:field, :label, :value]),
      error: error,
      status: :error
    }
  end

  defp combined_status(%{status: :error}, _capacity), do: :error
  defp combined_status(_anomaly, %{status: :error}), do: :error
  defp combined_status(_anomaly, _capacity), do: :ok

  defp filter_candidates(identity) do
    Enum.reject(
      [
        candidate(identity, :device_uid, "device_id", "device"),
        candidate(identity, :agent_id, "agent_id", "agent"),
        candidate(identity, :host_id, "host_id", "host")
      ],
      &is_nil/1
    )
  end

  defp capacity_candidates(candidates) do
    Enum.flat_map(candidates, fn candidate ->
      [
        %{candidate | field: "resource_id"},
        %{candidate | field: "resource_key", value: "%#{candidate.value}%"}
      ]
    end)
  end

  defp candidate(identity, key, field, label) do
    case Map.get(identity, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: %{field: field, label: label, value: value}

      _ ->
        nil
    end
  end

  defp anomaly_query(%{field: field, value: value}) do
    Enum.join(
      [
        "in:events",
        "class_uid:2004",
        "source_type:anomaly_detection",
        ~s|#{field}:"#{QueryData.escape_value(value)}"|,
        "time:last_7d",
        "sort:time:desc",
        "limit:#{@anomaly_limit}"
      ],
      " "
    )
  end

  defp capacity_query(%{field: field, value: value}) do
    Enum.join(
      [
        "in:capacity_forecasts",
        ~s|#{field}:"#{QueryData.escape_value(value)}"|,
        "sort:projected_exhaustion_at:asc",
        "limit:#{@capacity_limit}"
      ],
      " "
    )
  end

  defp metric_statuses(rows) do
    counts =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.group_by(&metric_class/1)

    Enum.map(@metric_classes, fn class ->
      class_rows = Map.get(counts, class, [])
      status = anomaly_status(class_rows)

      %{
        class: class,
        label: metric_label(class),
        status: status,
        count: length(class_rows),
        latest: List.first(class_rows)
      }
    end)
  end

  defp anomaly_status([]), do: "normal"

  defp anomaly_status(rows) do
    if Enum.any?(rows, &(status_value(&1) == "suppressed")) do
      "suppressed"
    else
      "active"
    end
  end

  defp metric_class(row) do
    row
    |> first_present([
      ["metric_class"],
      ["metadata", "service_radar", "metric_class"],
      ["metadata", "anomaly", "metric_class"],
      ["metadata", "detection_finding", "metric_class"],
      ["unmapped", "metric_class"],
      ["raw_data", "metric_class"]
    ])
    |> normalize_class()
  end

  defp status_value(row) do
    row
    |> first_present([
      ["status"],
      ["metadata", "service_radar", "status"],
      ["metadata", "anomaly", "status"],
      ["unmapped", "status"],
      ["raw_data", "status"]
    ])
    |> normalize_text()
  end

  defp first_present(row, paths) do
    Enum.find_value(paths, &nested_value(row, &1))
  end

  defp nested_value(value, []), do: value

  defp nested_value(%{} = row, [key | rest]) do
    row
    |> map_value(key)
    |> nested_value(rest)
  end

  defp nested_value(_row, _path), do: nil

  defp map_value(%{} = row, key) do
    Map.get(row, key) || Map.get(row, known_atom_key(key))
  end

  defp map_value(_row, _key), do: nil

  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("unmapped"), do: :unmapped
  defp known_atom_key("service_radar"), do: :service_radar
  defp known_atom_key("anomaly"), do: :anomaly
  defp known_atom_key("detection_finding"), do: :detection_finding
  defp known_atom_key("metric_class"), do: :metric_class
  defp known_atom_key("status"), do: :status
  defp known_atom_key(_), do: nil

  defp normalize_class(value) do
    value
    |> normalize_text()
    |> case do
      "memory_metrics" -> "memory"
      "cpu_metrics" -> "cpu"
      "disk_metrics" -> "disk"
      "interface_metrics" -> "interface"
      class when class in @metric_classes -> class
      _ -> "red"
    end
  end

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_text()
  defp normalize_text(value) when is_number(value), do: value |> to_string() |> normalize_text()
  defp normalize_text(_), do: ""

  defp metric_label("cpu"), do: "CPU"
  defp metric_label("memory"), do: "Memory"
  defp metric_label("disk"), do: "Disk"
  defp metric_label("interface"), do: "Interfaces"
  defp metric_label("red"), do: "RED"
  defp metric_label(class), do: class
end
