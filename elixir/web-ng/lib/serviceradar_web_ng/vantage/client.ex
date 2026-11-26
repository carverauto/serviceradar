defmodule ServiceRadarWebNG.Vantage.Client do
  @moduledoc """
  Thin NATS request/reply RPC client for `serviceradar-vantage` (`vantage.rpc.*`).

  Activated when `:vantage_rpc_enabled` is `true` (configured via
  `SERVICERADAR_VANTAGE_RPC_ENABLED=true` in `config/runtime.exs`).

  All RPC calls are fail-closed:
  - `capabilities/1` caches responses for 30s in ETS and returns
    `%{available: false}` on timeout, no-responders, or transport error.
  - `semantic_search/2` forwards pre-authorized camera scopes and maps JSON
    responses back to the `{:ok, result}` / `{:error, atom}` contract expected
    by `ServiceRadarWebNGWeb.CameraSemanticSearch`.
  - `frame_overlay/2` and `frame_overlay/3` fetch normalized bounding-box
    detections for a specific `(camera_source_id, visual_frame_id)`.
  """

  alias ServiceRadar.NATS.Connection, as: NATSConnection

  require Logger

  @capabilities_subject "vantage.rpc.capabilities.v1"
  @semantic_search_subject "vantage.rpc.semantic_search.v1"
  @frame_overlay_subject "vantage.rpc.frame_overlay.v1"

  @capabilities_cache_table :serviceradar_web_ng_vantage_capabilities_cache
  @capabilities_cache_key :capabilities
  @capabilities_ttl_ms 30_000
  @default_capabilities_timeout_ms 2_000
  @default_rpc_timeout_ms 5_000

  @known_error_reasons %{
    "unauthorized" => :unauthorized,
    "forbidden" => :forbidden,
    "permission_revoked" => :permission_revoked,
    "unauthorized_camera" => :unauthorized_camera,
    "camera_not_authorized" => :camera_not_authorized,
    "camera_source_not_found" => :camera_source_not_found,
    "invalid_request" => :invalid_request,
    "invalid_query" => :invalid_query,
    "invalid_camera_source_id" => :invalid_camera_source_id,
    "invalid_visual_frame_id" => :invalid_visual_frame_id,
    "invalid_stream_profile_id" => :invalid_stream_profile_id,
    "invalid_time_window" => :invalid_time_window,
    "window_too_large" => :window_too_large,
    "invalid_object_class" => :invalid_object_class,
    "invalid_color" => :invalid_color,
    "invalid_min_score" => :invalid_min_score,
    "invalid_limit" => :invalid_limit,
    "search_embedder_unavailable" => :search_embedder_unavailable,
    "embedder_unavailable" => :embedder_unavailable,
    "embedder_timeout" => :embedder_timeout,
    "nats_unavailable" => :nats_unavailable,
    "vantage_unavailable" => :vantage_unavailable,
    "semantic_search_unavailable" => :semantic_search_unavailable
  }

  @doc """
  Returns `true` when `SERVICERADAR_VANTAGE_RPC_ENABLED` is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:serviceradar_web_ng, :vantage_rpc_enabled, false) == true
  end

  @doc """
  Queries `vantage.rpc.capabilities.v1` with a 30-second ETS cache.

  Fails closed to `%{available: false}` on timeout, no-responders, NATS
  disconnect, or malformed responses.
  """
  @spec capabilities(keyword()) :: map()
  def capabilities(opts \\ []) when is_list(opts) do
    bypass_cache? = Keyword.get(opts, :bypass_cache, false) == true
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
    ttl_ms = Keyword.get(opts, :ttl_ms, @capabilities_ttl_ms)

    case if(bypass_cache?, do: :miss, else: cache_lookup(now_ms)) do
      {:ok, cached} ->
        cached

      :miss ->
        timeout_ms = Keyword.get(opts, :timeout_ms, @default_capabilities_timeout_ms)
        result = fetch_capabilities(timeout_ms, opts)

        if not bypass_cache? do
          cache_put(result, now_ms + ttl_ms)
        end

        result
    end
  end

  @doc """
  Clears the ETS capabilities cache (primarily for tests).
  """
  @spec clear_capabilities_cache() :: :ok
  def clear_capabilities_cache do
    case :ets.whereis(@capabilities_cache_table) do
      :undefined -> :ok
      tid -> :ets.delete_all_objects(tid)
    end

    :ok
  end

  @doc """
  Executes a semantic clip search over `vantage.rpc.semantic_search.v1`.

  Expects `params` to contain pre-authorized camera scopes
  (`authorized_camera_source_ids`, `camera_sources`) and validated search
  parameters.
  """
  @spec semantic_search(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def semantic_search(params, opts \\ []) when is_map(params) and is_list(opts) do
    timeout_ms =
      Keyword.get(
        opts,
        :timeout_ms,
        Application.get_env(
          :serviceradar_web_ng,
          :vantage_rpc_timeout_ms,
          @default_rpc_timeout_ms
        )
      )

    payload = build_semantic_search_payload(params)

    with {:ok, json} <- encode_payload(payload),
         {:ok, decoded} <- rpc_request(@semantic_search_subject, json, timeout_ms, opts) do
      parse_semantic_search_response(decoded)
    end
  end

  @doc """
  Fetches normalized bounding-box overlay detections for a specific visual frame
  over `vantage.rpc.frame_overlay.v1`.
  """
  @spec frame_overlay(map()) :: {:ok, [map()]} | {:error, atom()}
  def frame_overlay(params) when is_map(params), do: frame_overlay(params, [])

  @spec frame_overlay(map(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  @spec frame_overlay(String.t(), String.t()) :: {:ok, [map()]} | {:error, atom()}
  def frame_overlay(params, opts) when is_map(params) and is_list(opts) do
    camera_source_id = fetch_val(params, :camera_source_id)
    visual_frame_id = fetch_val(params, :visual_frame_id)

    if is_binary(camera_source_id) and is_binary(visual_frame_id) do
      frame_overlay(camera_source_id, visual_frame_id, opts)
    else
      {:error, :invalid_request}
    end
  end

  def frame_overlay(camera_source_id, visual_frame_id) when is_binary(camera_source_id) and is_binary(visual_frame_id) do
    frame_overlay(camera_source_id, visual_frame_id, [])
  end

  @spec frame_overlay(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def frame_overlay(camera_source_id, visual_frame_id, opts)
      when is_binary(camera_source_id) and is_binary(visual_frame_id) and is_list(opts) do
    timeout_ms =
      Keyword.get(
        opts,
        :timeout_ms,
        Application.get_env(
          :serviceradar_web_ng,
          :vantage_rpc_timeout_ms,
          @default_rpc_timeout_ms
        )
      )

    payload = %{
      "camera_source_id" => camera_source_id,
      "visual_frame_id" => visual_frame_id
    }

    with {:ok, json} <- encode_payload(payload),
         {:ok, decoded} <- rpc_request(@frame_overlay_subject, json, timeout_ms, opts) do
      parse_frame_overlay_response(decoded)
    end
  end

  @doc """
  Fetches normalized overlay detections for every frame with detections in a
  timeline window over `vantage.rpc.frame_overlay.v1`.

  Expects a pre-authorized `camera_source_id`, `from_us` < `to_us`, and an
  optional `stream_profile_id` and `limit`.
  """
  @spec frame_overlay_window(map(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def frame_overlay_window(params, opts \\ []) when is_map(params) and is_list(opts) do
    camera_source_id = fetch_val(params, :camera_source_id)
    from_us = fetch_val(params, :from_us)
    to_us = fetch_val(params, :to_us)

    if is_binary(camera_source_id) and is_integer(from_us) and is_integer(to_us) and to_us > from_us do
      timeout_ms =
        Keyword.get(
          opts,
          :timeout_ms,
          Application.get_env(:serviceradar_web_ng, :vantage_rpc_timeout_ms, @default_rpc_timeout_ms)
        )

      payload =
        %{"camera_source_id" => camera_source_id, "from_us" => from_us, "to_us" => to_us}
        |> maybe_put_payload("stream_profile_id", fetch_val(params, :stream_profile_id))
        |> maybe_put_payload("limit", fetch_val(params, :limit))

      with {:ok, json} <- encode_payload(payload),
           {:ok, decoded} <- rpc_request(@frame_overlay_subject, json, timeout_ms, opts) do
        parse_frame_overlay_response(decoded)
      end
    else
      {:error, :invalid_request}
    end
  end

  defp maybe_put_payload(payload, _key, nil), do: payload
  defp maybe_put_payload(payload, key, value), do: Map.put(payload, key, value)

  # ---------------------------------------------------------------------------
  # Payload construction & response parsing
  # ---------------------------------------------------------------------------

  defp fetch_capabilities(timeout_ms, opts) do
    with {:ok, json} <- encode_payload(%{}),
         {:ok, decoded} <- rpc_request(@capabilities_subject, json, timeout_ms, opts) do
      parse_capabilities_response(decoded)
    else
      _ -> %{available: false}
    end
  end

  defp parse_capabilities_response(%{"status" => "ok"} = body) do
    data = if is_map(body["data"]), do: body["data"], else: body
    available = Map.get(data, "available", true) == true

    %{
      available: available,
      version: Map.get(data, "version"),
      capabilities: Map.get(data, "capabilities") || %{},
      features: Map.get(data, "features") || []
    }
  end

  defp parse_capabilities_response(%{"available" => true} = body) do
    %{
      available: true,
      version: Map.get(body, "version"),
      capabilities: Map.get(body, "capabilities") || %{},
      features: Map.get(body, "features") || []
    }
  end

  defp parse_capabilities_response(_), do: %{available: false}

  defp build_semantic_search_payload(params) do
    authorized_ids =
      params
      |> fetch_val(:authorized_camera_source_ids)
      |> List.wrap()
      |> Enum.map(&to_string/1)

    camera_sources =
      params
      |> fetch_val(:camera_sources)
      |> normalize_camera_sources_payload()

    query = fetch_val(params, :query) || fetch_val(params, :q)

    %{
      "authorized_camera_source_ids" => authorized_ids,
      "camera_sources" => camera_sources,
      "q" => query,
      "query" => query
    }
    |> maybe_put("camera_source_id", fetch_val(params, :camera_source_id))
    |> maybe_put("camera_source_ids", fetch_val(params, :camera_source_ids))
    |> maybe_put("stream_profile_id", fetch_val(params, :stream_profile_id))
    |> maybe_put("from_us", fetch_val(params, :from_us))
    |> maybe_put("to_us", fetch_val(params, :to_us))
    |> maybe_put("object_class", fetch_val(params, :object_class))
    |> maybe_put("color", fetch_val(params, :color) || fetch_val(params, :dominant_color))
    |> maybe_put(
      "dominant_color",
      fetch_val(params, :dominant_color) || fetch_val(params, :color)
    )
    |> maybe_put("min_score", fetch_val(params, :min_score))
    |> maybe_put("limit", fetch_val(params, :limit))
  end

  defp normalize_camera_sources_payload(sources) when is_map(sources) do
    Map.new(sources, fn {id, meta} ->
      meta_map = if is_map(meta), do: meta, else: %{}

      {to_string(id),
       %{
         "display_name" => fetch_val(meta_map, :display_name),
         "device_uid" => fetch_val(meta_map, :device_uid)
       }}
    end)
  end

  defp normalize_camera_sources_payload(_), do: %{}

  defp parse_semantic_search_response(%{"status" => "ok"} = body) do
    data = if is_map(body["data"]), do: body["data"], else: body
    results = Map.get(data, "results") || Map.get(data, "hits") || []
    audit_meta = Map.get(body, "audit_meta") || Map.get(data, "audit_meta") || %{}

    {:ok,
     %{
       results: if(is_list(results), do: results, else: []),
       time_basis: Map.get(data, "time_basis"),
       time_uncertainty: Map.get(data, "time_uncertainty"),
       model_id: Map.get(data, "model_id"),
       model_version: Map.get(data, "model_version"),
       embedding_dim: Map.get(data, "embedding_dim"),
       audit_meta: if(is_map(audit_meta), do: audit_meta, else: %{})
     }}
  end

  defp parse_semantic_search_response(%{"status" => "error"} = body) do
    reason = Map.get(body, "error") || Map.get(body, "reason")
    {:error, map_error_reason(reason)}
  end

  defp parse_semantic_search_response(_), do: {:error, :vantage_unavailable}

  defp parse_frame_overlay_response(%{"status" => "ok"} = body) do
    raw_detections =
      cond do
        is_list(body["detections"]) -> body["detections"]
        is_map(body["data"]) and is_list(body["data"]["detections"]) -> body["data"]["detections"]
        is_list(body["data"]) -> body["data"]
        true -> []
      end

    {:ok, Enum.map(raw_detections, &normalize_overlay_detection/1)}
  end

  defp parse_frame_overlay_response(%{"status" => "error"} = body) do
    reason = Map.get(body, "error") || Map.get(body, "reason")
    {:error, map_error_reason(reason)}
  end

  defp parse_frame_overlay_response(_), do: {:error, :vantage_unavailable}

  defp normalize_overlay_detection(det) when is_map(det) do
    %{
      visual_frame_id: fetch_val(det, :visual_frame_id),
      timeline_ts_us: fetch_val(det, :timeline_ts_us),
      start_us: fetch_val(det, :start_us),
      end_us: fetch_val(det, :end_us),
      bbox: fetch_val(det, :bbox),
      object_class: fetch_val(det, :object_class) || "subject",
      score: fetch_val(det, :score) || 0.0,
      dominant_colors: det |> fetch_val(:dominant_colors) |> List.wrap() |> Enum.map(&to_string/1),
      time_basis: to_string(fetch_val(det, :time_basis) || "received")
    }
  end

  defp normalize_overlay_detection(_), do: %{}

  defp map_error_reason(reason) when is_binary(reason) do
    normalized = reason |> String.trim() |> String.downcase()
    Map.get(@known_error_reasons, normalized, :semantic_search_unavailable)
  end

  defp map_error_reason(reason) when is_atom(reason) and not is_nil(reason), do: reason
  defp map_error_reason(_), do: :semantic_search_unavailable

  # ---------------------------------------------------------------------------
  # NATS transport
  # ---------------------------------------------------------------------------

  defp rpc_request(subject, json_payload, timeout_ms, opts) do
    req_opts = [receive_timeout: timeout_ms]

    response =
      case resolve_request_fn(opts) do
        fun when is_function(fun, 3) ->
          fun.(subject, json_payload, req_opts)

        nil ->
          NATSConnection.request(subject, json_payload, req_opts)
      end

    case response do
      {:ok, %{status: "503"}} ->
        {:error, :vantage_unavailable}

      {:ok, %{headers: headers, body: ""}} when is_list(headers) ->
        if no_responders_headers?(headers) do
          {:error, :vantage_unavailable}
        else
          {:error, :vantage_unavailable}
        end

      {:ok, %{body: body}} when is_binary(body) ->
        decode_response(body)

      {:ok, body} when is_binary(body) ->
        decode_response(body)

      {:ok, body} when is_map(body) ->
        {:ok, body}

      {:error, :timeout} ->
        {:error, :vantage_unavailable}

      {:error, :no_responders} ->
        {:error, :vantage_unavailable}

      {:error, {:nats_not_connected, _}} ->
        {:error, :nats_unavailable}

      {:error, {:nats_connection_died, _}} ->
        {:error, :nats_unavailable}

      {:error, reason} ->
        Logger.debug("Vantage RPC request to #{subject} failed: #{inspect(reason)}")
        {:error, :vantage_unavailable}
    end
  end

  defp resolve_request_fn(opts) do
    Keyword.get(opts, :request_fn) ||
      Application.get_env(:serviceradar_web_ng, :vantage_rpc_request_fn)
  end

  defp no_responders_headers?(headers) do
    Enum.any?(headers, fn
      {key, "503"} when is_binary(key) -> String.downcase(key) == "status"
      _ -> false
    end)
  end

  defp encode_payload(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :invalid_request}
    end
  end

  defp decode_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :vantage_unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # ETS capabilities cache
  # ---------------------------------------------------------------------------

  defp ensure_cache_table do
    case :ets.whereis(@capabilities_cache_table) do
      :undefined ->
        try do
          :ets.new(@capabilities_cache_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true
          ])
        rescue
          ArgumentError -> :ets.whereis(@capabilities_cache_table)
        end

      tid ->
        tid
    end
  end

  defp cache_lookup(now_ms) do
    tid = ensure_cache_table()

    case :ets.lookup(tid, @capabilities_cache_key) do
      [{@capabilities_cache_key, value, expires_at_ms}] when expires_at_ms > now_ms ->
        {:ok, value}

      [{@capabilities_cache_key, _value, _expired}] ->
        :ets.delete(tid, @capabilities_cache_key)
        :miss

      _ ->
        :miss
    end
  end

  defp cache_put(value, expires_at_ms) do
    tid = ensure_cache_table()
    :ets.insert(tid, {@capabilities_cache_key, value, expires_at_ms})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fetch_val(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
