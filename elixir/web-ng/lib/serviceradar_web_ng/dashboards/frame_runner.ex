defmodule ServiceRadarWebNG.Dashboards.FrameRunner do
  @moduledoc """
  Executes approved dashboard package SRQL data frames.

  Renderers never receive database credentials or arbitrary query access. They
  receive bounded frame payloads produced from the queries declared in the
  verified dashboard package manifest.
  """

  @default_frame_limit 500
  @max_frame_limit 2_000
  @max_frames 12

  @spec run([map()], term(), keyword()) :: [map()]
  def run(data_frames, scope, opts \\ [])

  def run(data_frames, scope, opts) when is_list(data_frames) do
    limit = frame_limit(opts)
    srql_module = Keyword.get(opts, :srql_module, srql_module())

    data_frames
    |> Enum.take(@max_frames)
    |> Enum.map(&run_frame(&1, scope, srql_module, limit))
  end

  def run(_data_frames, _scope, _opts), do: []

  defp run_frame(%{} = frame, scope, srql_module, default_limit) do
    id = normalize_string(frame["id"] || frame[:id]) || "frame"
    query = normalize_string(frame["query"] || frame[:query])
    requested_encoding = normalize_string(frame["encoding"] || frame[:encoding]) || "json_rows"
    limit = frame_limit(frame["limit"] || frame[:limit], default_limit)

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
        run_arrow_or_json_frame(base, query, scope, srql_module, limit)

      true ->
        run_json_frame(base, query, scope, srql_module, limit)
    end
  end

  defp run_frame(_frame, _scope, _srql_module, default_limit) do
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

  defp run_arrow_or_json_frame(base, query, scope, srql_module, limit) do
    case run_arrow_frame(base, query, scope, srql_module, limit) do
      {:ok, frame} -> frame
      {:fallback, _reason} -> run_json_frame(base, query, scope, srql_module, limit)
      {:error, reason} -> error_frame(base, reason)
    end
  end

  defp run_arrow_frame(base, query, scope, srql_module, limit) do
    if function_exported?(srql_module, :query_arrow, 2) do
      case srql_module.query_arrow(query, %{scope: scope, limit: limit}) do
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

  defp run_json_frame(base, query, scope, srql_module, limit) do
    case srql_module.query(query, %{scope: scope, limit: limit}) do
      {:ok, %{"results" => results} = response} when is_list(results) ->
        Map.merge(base, %{
          "status" => "ok",
          "results" => results,
          "pagination" => Map.get(response, "pagination"),
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

  defp error_frame(base, reason) do
    Map.merge(base, %{
      "status" => "error",
      "error" => format_error(reason),
      "results" => []
    })
  end

  defp required?(frame) do
    case frame["required"] || frame[:required] do
      false -> false
      _ -> true
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
