defmodule ServiceRadarWebNGWeb.DeviceLive.AvailabilityData do
  @moduledoc false

  alias ServiceRadar.Inventory.Availability.DeviceEvidence
  alias ServiceRadar.Inventory.Availability.VantageExpectation
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadarWebNG.Devices.MergedAvailability
  alias ServiceRadarWebNGWeb.DeviceLive.ICMPData

  require Ash.Query

  @bucket_seconds 30 * 60
  @microseconds 1_000_000
  @window_seconds 24 * 60 * 60
  # One row per bucket and probed address: a full window spans up to 49 buckets, and a sweep probes a
  # device at its own address plus up to eight aliases.
  @row_limit 500
  # One record per change of the device's merged state; a day holds few of them.
  @history_limit 1_000

  @doc """
  The device's Availability Timeline over the last 24 hours, in 30-minute buckets.

  With no agent selected, once core has converged onto merged availability
  (`MergedAvailability.converged?/0`), the timeline is the history of the device's merged
  availability, the value its badge shows (`fix-device-availability-timeline`, design
  Decision 3): the current decision covers the time since `availability_changed_at`, and
  each `in:device_availability_history` record covers the interval it closes. Time
  neither covers is unknown, never synthesized. Before convergence, and whenever an agent
  is selected, the timeline is probe history (`ICMPData.load_availability/4`) and says so
  in `:source`.

  Options: `:agent_id`, `:now`, `:merged_availability` (the device's merged summary, or a
  0-arity loader for it) and `:converged?` (a boolean, or a 0-arity loader).
  """
  def load_availability(srql_module, device_uid, scope, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    probe_end = DateTime.truncate(now, :second)
    start_at = DateTime.shift(probe_end, second: -@window_seconds)
    agent_id = Keyword.get(opts, :agent_id)

    cond do
      is_binary(agent_id) ->
        load_probe_history(srql_module, device_uid, scope, agent_id, :agent_probe, start_at, probe_end)

      resolve(Keyword.get(opts, :converged?, &MergedAvailability.converged?/0)) ->
        merged = resolve(Keyword.get(opts, :merged_availability)) || %{}
        load_merged_history(srql_module, device_uid, scope, merged, start_at, now)

      true ->
        load_probe_history(srql_module, device_uid, scope, nil, :probe, start_at, probe_end)
    end
  end

  defp resolve(loader) when is_function(loader, 0), do: loader.()
  defp resolve(value), do: value

  defp load_probe_history(srql_module, device_uid, scope, agent_id, source, start_at, now) do
    range = "[#{DateTime.to_iso8601(start_at)},#{DateTime.to_iso8601(now)}]"

    case ICMPData.load_availability(srql_module, device_uid, scope,
           time_range: range,
           bucket: "30m",
           agent_id: agent_id,
           limit: @row_limit
         ) do
      {:ok, rows} ->
        rows |> build_availability(start_at, now) |> Map.put(:source, source)

      {:error, _reason} ->
        nil
    end
  end

  defp load_merged_history(srql_module, device_uid, scope, merged, start_at, now) do
    query =
      ~s(in:device_availability_history uid:"#{escape_value(device_uid)}" ) <>
        "time:[#{DateTime.to_iso8601(start_at)},#{DateTime.to_iso8601(now)}] " <>
        "sort:changed_at:asc limit:#{@history_limit}"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => records}} when is_list(records) ->
        records
        |> history_intervals(merged, start_at, now)
        |> build_merged_availability(start_at, now)

      _ ->
        nil
    end
  end

  # Each record closes `[from_since, changed_at)` in `from_state`; the current decision
  # holds over `[changed_at, now]`. A record without `from_since` closes an interval whose
  # start is not known, so it covers nothing. Intervals are clipped to the window.
  defp history_intervals(records, merged, start_at, now) do
    closed =
      Enum.flat_map(records, fn record ->
        with {:ok, from_since} <- parse_timestamp(record["from_since"]),
             {:ok, changed_at} <- parse_timestamp(record["changed_at"]) do
          record["from_state"]
          |> MergedAvailability.state()
          |> interval(from_since, changed_at, start_at, now)
        else
          _ -> []
        end
      end)

    current =
      case merged do
        %{state: state, changed_at: %DateTime{} = changed_at} ->
          state |> MergedAvailability.state() |> interval(changed_at, now, start_at, now)

        _ ->
          []
      end

    closed ++ current
  end

  defp interval(state, from, until, start_at, now) when state in [:available, :unavailable] do
    from = latest(from, start_at)
    until = earliest(until, now)

    if DateTime.before?(from, until),
      do: [{state, DateTime.to_unix(from, :microsecond), DateTime.to_unix(until, :microsecond)}],
      else: []
  end

  defp interval(_state, _from, _until, _start_at, _now), do: []

  defp latest(a, b), do: if(DateTime.before?(a, b), do: b, else: a)
  defp earliest(a, b), do: if(DateTime.after?(a, b), do: b, else: a)

  # A bucket is offline when the device was unavailable for any part of it, online when
  # every known part of it was available, and unknown when no part is known. Uptime is
  # available time over known time, all measured in microseconds.
  defp build_merged_availability(intervals, start_at, end_at) do
    first = DateTime.to_unix(start_at, :microsecond)
    last = DateTime.to_unix(end_at, :microsecond)
    last_bucket = (last - 1) |> Integer.floor_div(@microseconds) |> bucket_start()

    buckets =
      Enum.map(bucket_start(DateTime.to_unix(start_at))..last_bucket//@bucket_seconds, fn second ->
        from = max(second * @microseconds, first)
        until = min((second + @bucket_seconds) * @microseconds, last)
        up = overlap(intervals, :available, from, until)
        down = overlap(intervals, :unavailable, from, until)
        {second, until - from, up, down}
      end)

    segments =
      Enum.map(buckets, fn {second, span, up, down} ->
        state = merged_status(up, down)

        %{
          timestamp: second |> DateTime.from_unix!() |> DateTime.to_iso8601(),
          status: state,
          available: state == :online,
          minutes_down: minutes(down),
          width: span / (last - first) * 100.0,
          title: merged_label(state, down)
        }
      end)

    up = buckets |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    known = up + (buckets |> Enum.map(&elem(&1, 3)) |> Enum.sum())
    online = Enum.count(segments, &(&1.status == :online))
    offline = Enum.count(segments, &(&1.status == :offline))

    %{
      uptime_pct: if(known > 0, do: Float.round(up / known * 100.0, 1)),
      total_checks: online + offline,
      online_checks: online,
      offline_checks: offline,
      unknown_checks: length(segments) - online - offline,
      bucket_count: length(segments),
      window_start: start_at,
      window_end: end_at,
      segments: segments,
      source: :merged
    }
  end

  defp overlap(intervals, state, from, until) do
    for {^state, a, b} <- intervals, reduce: 0 do
      acc -> acc + max(0, min(b, until) - max(a, from))
    end
  end

  defp merged_status(_up, down) when down > 0, do: :offline
  defp merged_status(up, _down) when up > 0, do: :online
  defp merged_status(_up, _down), do: :unknown

  defp minutes(microseconds), do: div(microseconds + 60 * @microseconds - 1, 60 * @microseconds)

  defp merged_label(:offline, down), do: "Offline (#{minutes(down)} min down)"
  defp merged_label(:online, _down), do: "Online"
  defp merged_label(:unknown, _down), do: "Unknown (no recorded state)"

  def source_agent_id(device_row) when is_map(device_row) do
    case Map.get(device_row, "availability_source_agent_id") ||
           Map.get(device_row, :availability_source_agent_id) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          agent_id -> agent_id
        end

      _ ->
        nil
    end
  end

  def source_agent_id(_device_row), do: nil

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

  @doc """
  The device's canonical availability for the details page: the resolver's decision
  plus the non-probe evidence records and the vantage expectations (which agent a
  composite check expects to reach the device, and which it expects to be blocked).
  `nil` when the device is not found.
  """
  def load_device_availability(scope, device_uid) when is_binary(device_uid) do
    case MergedAvailability.load([device_uid]) do
      %{^device_uid => summary} ->
        summary
        |> Map.put(:evidence, read_all(DeviceEvidence, device_uid, scope))
        |> Map.put(:expectations, expectations(read_all(VantageExpectation, device_uid, scope)))

      _ ->
        nil
    end
  end

  def load_device_availability(_scope, _device_uid), do: nil

  defp read_all(resource, device_uid, scope) do
    resource
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(device_uid == ^device_uid)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, rows} when is_list(rows) -> rows
      _ -> []
    end
  end

  # An agent any check expects to be blocked is a negative control, whatever another
  # check expects of it; the resolver reads the expectations the same way.
  defp expectations(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      Map.update(acc, row.agent_id, row.expectation, fn
        :blocked -> :blocked
        _ -> row.expectation
      end)
    end)
  end

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
