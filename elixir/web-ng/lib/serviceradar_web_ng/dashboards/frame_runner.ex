defmodule ServiceRadarWebNG.Dashboards.FrameRunner do
  @moduledoc """
  Executes approved dashboard package SRQL data frames.

  Renderers never receive database credentials or arbitrary query access. They
  receive bounded frame payloads produced from the queries declared in the
  verified dashboard package manifest.
  """

  alias ServiceRadar.EventWriter.DeviceCorrelation

  @default_frame_limit 500
  @max_frame_limit 2_000
  @max_frames 12
  @default_frame_timeout_ms 10_000
  @max_frame_timeout_ms 30_000
  @default_frame_concurrency 6
  @event_frame_entities ~w(events security_findings scan_activity dns_activity)
  @synthetic_frame_fields ~w(resolved_device_uid)

  @spec run([map()], term(), keyword()) :: [map()]
  def run(data_frames, scope, opts \\ [])

  def run(data_frames, scope, opts) when is_list(data_frames) do
    limit = frame_limit(opts)
    srql_module = Keyword.get(opts, :srql_module, srql_module())
    device_resolver = Keyword.get(opts, :device_resolver, DeviceCorrelation)
    timeout = frame_timeout(opts)
    max_concurrency = frame_concurrency(opts)

    data_frames
    |> Enum.take(@max_frames)
    |> Task.async_stream(&run_frame(&1, scope, srql_module, device_resolver, limit),
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(Enum.take(data_frames, @max_frames))
    |> Enum.map(fn
      {{:ok, frame}, _source_frame} -> frame
      {{:exit, :timeout}, source_frame} -> timeout_frame(source_frame, limit)
      {{:exit, reason}, source_frame} -> failed_frame(source_frame, limit, reason)
    end)
  end

  def run(_data_frames, _scope, _opts), do: []

  defp run_frame(%{} = frame, scope, srql_module, device_resolver, default_limit) do
    id = normalize_string(frame["id"] || frame[:id]) || "frame"
    query = normalize_string(frame["query"] || frame[:query])
    requested_encoding = normalize_string(frame["encoding"] || frame[:encoding]) || "json_rows"
    limit = frame_limit(frame["limit"] || frame[:limit], default_limit)
    cursor = normalize_string(frame["cursor"] || frame[:cursor])
    fields = frame_fields(frame)
    srql_opts = srql_query_opts(scope, limit, cursor)

    base = %{
      "id" => id,
      "query" => query,
      "requested_encoding" => requested_encoding,
      "encoding" => "json_rows",
      "limit" => limit,
      "required" => required?(frame)
    }

    cond do
      is_nil(query) ->
        Map.merge(base, %{"status" => "error", "error" => "missing query", "results" => []})

      requested_encoding == "arrow_ipc" ->
        run_arrow_or_json_frame(base, query, srql_opts, srql_module, device_resolver, fields)

      true ->
        run_json_frame(base, query, srql_opts, srql_module, device_resolver, fields)
    end
  end

  defp run_frame(_frame, _scope, _srql_module, _device_resolver, default_limit) do
    %{
      "id" => "invalid",
      "query" => nil,
      "requested_encoding" => "json_rows",
      "encoding" => "json_rows",
      "limit" => default_limit,
      "required" => true,
      "status" => "error",
      "error" => "data frame must be an object",
      "results" => []
    }
  end

  defp run_arrow_or_json_frame(base, query, srql_opts, srql_module, device_resolver, fields) do
    case run_arrow_frame(base, query, srql_opts, srql_module) do
      {:ok, frame} ->
        frame

      {:fallback, _reason} ->
        run_json_frame(base, query, srql_opts, srql_module, device_resolver, fields)

      {:error, reason} ->
        error_frame(base, reason)
    end
  end

  defp run_arrow_frame(base, query, srql_opts, srql_module) do
    if function_exported?(srql_module, :query_arrow, 2) do
      case srql_module.query_arrow(query, srql_opts) do
        {:ok, bytes} when is_binary(bytes) ->
          {:ok, arrow_frame(base, bytes, %{})}

        {:ok, %{"payload" => bytes} = response} when is_binary(bytes) ->
          {:ok, arrow_frame(base, bytes, response)}

        {:ok, %{payload: bytes} = response} when is_binary(bytes) ->
          {:ok, arrow_frame(base, bytes, response)}

        {:error, :arrow_not_supported} ->
          {:fallback, :arrow_not_supported}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:unexpected_srql_arrow_result, other}}
      end
    else
      {:fallback, :arrow_not_supported}
    end
  end

  defp arrow_frame(base, bytes, response) do
    Map.merge(base, %{
      "status" => "ok",
      "encoding" => "arrow_ipc",
      "payload_encoding" => "base64",
      "payload" => Base.encode64(bytes),
      "byte_length" => byte_size(bytes),
      "results" => [],
      "pagination" => response_value(response, "pagination"),
      "schema" => response_value(response, "schema"),
      "viz" => response_value(response, "viz")
    })
  end

  defp run_json_frame(base, query, srql_opts, srql_module, device_resolver, fields) do
    case srql_module.query(query, srql_opts) do
      {:ok, %{"results" => results} = response} when is_list(results) ->
        results =
          query
          |> maybe_enrich_event_results(results, device_resolver)
          |> project_results(fields)

        Map.merge(base, %{
          "status" => "ok",
          "results" => results,
          "pagination" => Map.get(response, "pagination"),
          "schema" => Map.get(response, "schema"),
          "viz" => Map.get(response, "viz")
        })

      {:ok, response} ->
        Map.merge(base, %{
          "status" => "ok",
          "results" => [],
          "raw" => response
        })

      {:error, reason} ->
        error_frame(base, reason)
    end
  end

  defp maybe_enrich_event_results(query, results, device_resolver) do
    if event_query?(query) do
      Enum.map(results, &enrich_event_result(&1, device_resolver))
    else
      results
    end
  end

  defp event_query?(query) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)in:([a-zA-Z0-9_]+)/, query) do
      [_, entity] -> entity in @event_frame_entities
      _ -> false
    end
  end

  defp event_query?(_query), do: false

  defp enrich_event_result(row, device_resolver) when is_map(row) do
    case resolve_device_uid(row, device_resolver) do
      uid when is_binary(uid) and uid != "" -> Map.put(row, "resolved_device_uid", uid)
      _ -> row
    end
  end

  defp enrich_event_result(row, _device_resolver), do: row

  defp project_results(results, nil), do: results

  defp project_results(results, fields) when is_list(fields) do
    Enum.map(results, &project_result(&1, fields))
  end

  defp project_result(row, fields) when is_map(row) do
    fields
    |> Enum.concat(@synthetic_frame_fields)
    |> Enum.reduce(%{}, fn field, acc ->
      case fetch_projected_value(row, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp project_result(row, _fields), do: row

  defp fetch_projected_value(row, field) when is_binary(field) do
    if Map.has_key?(row, field) do
      {:ok, Map.get(row, field)}
    else
      atom_field = String.to_existing_atom(field)

      if Map.has_key?(row, atom_field) do
        {:ok, Map.get(row, atom_field)}
      else
        :error
      end
    end
  rescue
    ArgumentError -> :error
  end

  defp resolve_device_uid(row, device_resolver) do
    candidate = device_candidate(row)

    cond do
      is_atom(device_resolver) and function_exported?(device_resolver, :resolve, 1) ->
        device_resolver.resolve(candidate)

      is_function(device_resolver, 1) ->
        device_resolver.(candidate)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp device_candidate(row) do
    raw = raw_data(row)
    raw_correlation = map_value(raw, "correlation") || %{}

    raw_output_fields =
      %{}
      |> Map.merge(normalized_map(map_value(raw, "output_fields")))
      |> Map.merge(normalized_map(map_value(raw, "custom_fields")))
      |> Map.merge(normalized_map(map_value(raw, "templated_fields")))

    %{
      device_uid:
        first_present([
          value(row, "resolved_device_uid"),
          value(row, "source_device_uid"),
          value(row, "device_uid"),
          string_at(row, ["metadata", "service_radar", "device_uid"]),
          string_at(row, ["metadata", "service_radar", "device", "id"]),
          string_at(row, ["metadata", "service_radar", "device_id"]),
          map_value(raw_output_fields, "service_radar.device_uid"),
          map_value(raw_output_fields, "service_radar.device.uid"),
          map_value(raw_output_fields, "service_radar.device_id"),
          map_value(raw_output_fields, "serviceradar.device_uid"),
          map_value(raw_output_fields, "serviceradar.device.uid"),
          map_value(raw_output_fields, "serviceradar.device_id"),
          string_at(row, ["metadata", "serviceradar", "device_uid"]),
          string_at(row, ["device", "uid"]),
          string_at(row, ["unmapped", "device_uid"]),
          string_at(raw, ["metadata", "service_radar", "device_uid"]),
          string_at(raw, ["metadata", "service_radar", "device", "id"]),
          string_at(raw, ["metadata", "service_radar", "device_id"]),
          string_at(raw, ["metadata", "serviceradar", "device_uid"]),
          string_at(raw, ["device", "uid"]),
          string_at(raw, ["unmapped", "device_uid"]),
          map_value(raw_correlation, "device_uid"),
          map_value(raw_correlation, "device_id")
        ]),
      agent_id:
        first_present([
          value(row, "agent_id"),
          string_at(row, ["metadata", "service_radar", "agent_id"]),
          string_at(row, ["metadata", "serviceradar", "agent_id"]),
          string_at(row, ["unmapped", "agent_id"]),
          string_at(raw, ["metadata", "service_radar", "agent_id"]),
          string_at(raw, ["metadata", "serviceradar", "agent_id"]),
          string_at(raw, ["unmapped", "agent_id"]),
          map_value(raw_correlation, "agent_id"),
          map_value(raw_output_fields, "service_radar.agent_id"),
          map_value(raw_output_fields, "serviceradar.agent_id"),
          map_value(raw_output_fields, "agent_id")
        ]),
      hostname:
        first_present([
          string_at(row, ["device", "hostname"]),
          string_at(row, ["device", "name"]),
          string_at(row, ["metadata", "service_radar", "device_hostname"]),
          string_at(row, ["metadata", "service_radar", "source_instance"]),
          string_at(row, ["metadata", "hostname"]),
          string_at(row, ["unmapped", "device_name"]),
          string_at(row, ["unmapped", "server_identity"]),
          string_at(raw, ["device", "hostname"]),
          string_at(raw, ["device", "name"]),
          string_at(raw, ["metadata", "service_radar", "device_hostname"]),
          string_at(raw, ["metadata", "service_radar", "source_instance"]),
          string_at(raw, ["metadata", "hostname"]),
          string_at(raw, ["unmapped", "device_name"]),
          string_at(raw, ["unmapped", "server_identity"]),
          map_value(raw_correlation, "node_name"),
          map_value(raw_correlation, "hostname"),
          map_value(raw_output_fields, "k8s.node.name"),
          map_value(raw_output_fields, "host.name"),
          value(row, "host")
        ]),
      name:
        first_present([
          string_at(row, ["device", "name"]),
          map_value(raw_correlation, "resource_name"),
          map_value(raw_correlation, "owner_name")
        ]),
      ip:
        first_present([
          string_at(row, ["metadata", "service_radar", "source_ip"]),
          string_at(row, ["metadata", "service_radar", "device_ip"]),
          string_at(row, ["src_endpoint", "ip"]),
          string_at(raw, ["metadata", "service_radar", "source_ip"]),
          string_at(raw, ["metadata", "service_radar", "device_ip"]),
          string_at(raw, ["src_endpoint", "ip"]),
          map_value(raw_correlation, "host_ip"),
          map_value(raw_correlation, "pod_ip"),
          map_value(raw_output_fields, "service_radar.device_ip"),
          map_value(raw_output_fields, "service_radar.source_ip"),
          map_value(raw_output_fields, "serviceradar.device_ip"),
          map_value(raw_output_fields, "serviceradar.source_ip"),
          map_value(raw_output_fields, "host.ip"),
          map_value(raw_output_fields, "evt.host.ip")
        ]),
      partition:
        first_present([
          string_at(row, ["metadata", "service_radar", "partition_id"]),
          string_at(raw, ["metadata", "service_radar", "partition_id"])
        ])
    }
  end

  defp raw_data(row) do
    case map_value(row, "raw_data") do
      raw when is_map(raw) ->
        raw

      raw when is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp normalized_map(value) when is_map(value), do: value
  defp normalized_map(_value), do: %{}

  defp string_at(value, path) when is_list(path) do
    path
    |> Enum.reduce_while(value, fn key, acc ->
      case map_value(acc, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
    |> normalize_string()
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_value(_map, _key), do: nil

  defp value(row, key), do: normalize_string(map_value(row, key))

  defp first_present(values) do
    Enum.find_value(values, &normalize_string/1)
  end

  defp error_frame(base, reason) do
    Map.merge(base, %{
      "status" => "error",
      "error" => format_error(reason),
      "results" => []
    })
  end

  defp timeout_frame(frame, default_limit), do: failed_frame(frame, default_limit, :frame_timeout)

  defp failed_frame(frame, default_limit, reason) when is_map(frame) do
    id = normalize_string(frame["id"] || frame[:id]) || "frame"
    query = normalize_string(frame["query"] || frame[:query])
    requested_encoding = normalize_string(frame["encoding"] || frame[:encoding]) || "json_rows"
    limit = frame_limit(frame["limit"] || frame[:limit], default_limit)

    %{
      "id" => id,
      "query" => query,
      "requested_encoding" => requested_encoding,
      "encoding" => "json_rows",
      "limit" => limit,
      "required" => required?(frame),
      "status" => "error",
      "error" => format_error(reason),
      "results" => []
    }
  end

  defp failed_frame(_frame, default_limit, reason) do
    %{
      "id" => "invalid",
      "query" => nil,
      "requested_encoding" => "json_rows",
      "encoding" => "json_rows",
      "limit" => default_limit,
      "required" => true,
      "status" => "error",
      "error" => format_error(reason),
      "results" => []
    }
  end

  defp required?(frame) do
    case frame_value(frame, "required", :required) do
      false -> false
      _ -> true
    end
  end

  defp frame_value(frame, string_key, atom_key) when is_map(frame) do
    cond do
      Map.has_key?(frame, string_key) -> Map.get(frame, string_key)
      Map.has_key?(frame, atom_key) -> Map.get(frame, atom_key)
      true -> nil
    end
  end

  defp frame_fields(frame) when is_map(frame) do
    frame
    |> frame_value("fields", :fields)
    |> normalize_fields()
  end

  defp frame_fields(_frame), do: nil

  defp normalize_fields(fields) when is_list(fields) do
    fields
    |> Enum.map(&normalize_field/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      normalized -> normalized
    end
  end

  defp normalize_fields(_fields), do: nil

  defp normalize_field(field) when is_atom(field), do: field |> Atom.to_string() |> normalize_string()
  defp normalize_field(field) when is_binary(field), do: normalize_string(field)
  defp normalize_field(_field), do: nil

  defp srql_query_opts(scope, limit, cursor) do
    opts = %{scope: scope, limit: limit}

    case cursor do
      cursor when is_binary(cursor) and cursor != "" -> Map.put(opts, :cursor, cursor)
      _ -> opts
    end
  end

  defp frame_limit(opts) when is_list(opts) do
    opts |> Keyword.get(:limit, @default_frame_limit) |> frame_limit(@default_frame_limit)
  end

  defp frame_limit(value, _default) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_frame_limit)
  end

  defp frame_limit(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> frame_limit(int, default)
      _ -> default
    end
  end

  defp frame_limit(_value, default), do: default

  defp frame_timeout(opts) when is_list(opts) do
    opts
    |> Keyword.get(:frame_timeout_ms, @default_frame_timeout_ms)
    |> normalize_positive_integer(@default_frame_timeout_ms)
    |> min(@max_frame_timeout_ms)
  end

  defp frame_concurrency(opts) when is_list(opts) do
    opts
    |> Keyword.get(:max_concurrency, @default_frame_concurrency)
    |> normalize_positive_integer(@default_frame_concurrency)
    |> min(@max_frames)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value), do: max(value, 1)

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> normalize_positive_integer(int, default)
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_value), do: nil

  defp response_value(response, "pagination") when is_map(response),
    do: Map.get(response, "pagination") || Map.get(response, :pagination)

  defp response_value(response, "schema") when is_map(response),
    do: Map.get(response, "schema") || Map.get(response, :schema)

  defp response_value(response, "viz") when is_map(response), do: Map.get(response, "viz") || Map.get(response, :viz)

  defp response_value(_response, _key), do: nil

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
