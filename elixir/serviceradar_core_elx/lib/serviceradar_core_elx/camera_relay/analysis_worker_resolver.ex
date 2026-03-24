defmodule ServiceRadarCoreElx.CameraRelay.AnalysisWorkerResolver do
  @moduledoc """
  Resolves registered camera analysis workers for relay-scoped dispatch.
  """

  alias ServiceRadar.Camera.AnalysisWorker

  @supported_http_adapters ["http"]
  @default_flapping_transition_threshold 3
  @default_unhealthy_alert_failure_threshold 3

  def resolve_http_worker(attrs, opts \\ []) do
    resource = Keyword.get(opts, :resource, AnalysisWorker)

    case selection_request(attrs) do
      {:direct, worker} ->
        {:ok,
         Map.merge(worker, %{
           selection_mode: "direct",
           requested_capability: nil,
           registry_managed?: false
         })}

      {:worker_id, worker_id, requested_capability} ->
        case resolve_registered_worker(resource, worker_id, requested_capability, opts) do
          nil -> {:error, :worker_not_found}
          other -> other
        end

      {:capability, requested_capability, excluded_worker_ids} ->
        resolve_by_capability(resource, requested_capability, excluded_worker_ids, opts)

      :error ->
        {:error, :worker_target_required}
    end
  end

  def mark_worker_healthy(worker_id, opts \\ []) when is_binary(worker_id) do
    resource = Keyword.get(opts, :resource, AnalysisWorker)
    now = DateTime.utc_now()

    with {:ok, worker} <- resource.get_by_worker_id(worker_id, actor_option(opts)),
         false <- is_nil(worker),
         attrs =
           %{health_status: "healthy", health_reason: nil, last_healthy_at: now, consecutive_failures: 0}
           |> maybe_put_recent_probe_result(worker, "healthy", nil, now, opts)
           |> maybe_put_transition_timestamp(worker, now, "healthy")
           |> put_flapping_state(worker, opts),
         attrs = put_alert_state(attrs, worker, opts),
         {:ok, updated_worker} <-
           resource.update_worker(worker, attrs, actor_option(opts)) do
      {:ok, normalize_worker(updated_worker)}
    else
      true -> {:error, :worker_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_worker_unhealthy(worker_id, reason, opts \\ []) when is_binary(worker_id) do
    resource = Keyword.get(opts, :resource, AnalysisWorker)
    health_reason = normalize_health_reason(reason)
    now = DateTime.utc_now()

    with {:ok, worker} <- resource.get_by_worker_id(worker_id, actor_option(opts)),
         false <- is_nil(worker),
         attrs =
           %{
             health_status: "unhealthy",
             health_reason: health_reason,
             last_failure_at: now,
             consecutive_failures: map_value(worker, :consecutive_failures, 0) + 1
           }
           |> maybe_put_recent_probe_result(worker, "unhealthy", health_reason, now, opts)
           |> maybe_put_transition_timestamp(worker, now, "unhealthy")
           |> put_flapping_state(worker, opts),
         attrs = put_alert_state(attrs, worker, opts),
         {:ok, updated_worker} <-
           resource.update_worker(worker, attrs, actor_option(opts)) do
      {:ok, normalize_worker(updated_worker)}
    else
      true -> {:error, :worker_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_worker_alert(worker_id, opts \\ []) when is_binary(worker_id) do
    resource = Keyword.get(opts, :resource, AnalysisWorker)

    with {:ok, worker} <- resource.get_by_worker_id(worker_id, actor_option(opts)),
         false <- is_nil(worker),
         attrs = put_alert_state(%{}, worker, opts),
         {:ok, updated_worker} <- resource.update_worker(worker, attrs, actor_option(opts)) do
      {:ok, normalize_worker(updated_worker)}
    else
      true -> {:error, :worker_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_registered_worker(resource, worker_id, requested_capability, opts) do
    case resource.get_by_worker_id(worker_id, actor_option(opts)) do
      {:ok, nil} ->
        nil

      {:ok, worker} ->
        with :ok <- ensure_enabled(worker),
             :ok <- ensure_healthy(worker),
             :ok <- ensure_capability(worker, requested_capability),
             :ok <- ensure_http_adapter(worker) do
          {:ok,
           worker
           |> normalize_worker()
           |> Map.put(:selection_mode, "worker_id")
           |> Map.put(:requested_capability, requested_capability)
           |> Map.put(:registry_managed?, true)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp selection_request(attrs) do
    direct_endpoint_url = present_string(attrs, :endpoint_url)
    registered_worker_id = present_string(attrs, :registered_worker_id)
    excluded_worker_ids = excluded_worker_ids(attrs)

    fallback_worker_id =
      if is_nil(direct_endpoint_url), do: present_string(attrs, :worker_id)

    requested_capability = requested_capability(attrs)

    cond do
      is_binary(registered_worker_id) ->
        {:worker_id, registered_worker_id, requested_capability}

      is_binary(requested_capability) ->
        {:capability, requested_capability, excluded_worker_ids}

      is_binary(direct_endpoint_url) ->
        {:direct,
         %{
           worker_id: required_direct_worker_id!(attrs),
           endpoint_url: direct_endpoint_url,
           adapter: "http",
           headers: map_value(attrs, :headers, %{}),
           capabilities: [],
           enabled: true
         }}

      is_binary(fallback_worker_id) ->
        {:worker_id, fallback_worker_id, requested_capability}

      true ->
        :error
    end
  end

  defp resolve_by_capability(resource, requested_capability, excluded_worker_ids, opts) do
    case resource.list_enabled(actor_option(opts)) do
      {:ok, workers} ->
        workers = Enum.map(workers, &normalize_worker/1)

        matching_workers =
          Enum.filter(workers, fn worker ->
            requested_capability in (worker.capabilities || []) and
              worker.worker_id not in excluded_worker_ids
          end)

        case Enum.find(matching_workers, &(healthy_worker?(&1) and http_worker?(&1))) do
          nil ->
            if Enum.empty?(matching_workers) do
              {:error, :worker_capability_unmatched}
            else
              {:error, :worker_unavailable}
            end

          worker ->
            {:ok,
             worker
             |> Map.put(:selection_mode, "capability")
             |> Map.put(:requested_capability, requested_capability)
             |> Map.put(:registry_managed?, true)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_worker(worker) when is_map(worker) do
    %{
      worker_id: map_value(worker, :worker_id),
      display_name: map_value(worker, :display_name),
      adapter: map_value(worker, :adapter, "http"),
      endpoint_url: map_value(worker, :endpoint_url),
      health_endpoint_url: map_value(worker, :health_endpoint_url),
      health_path: map_value(worker, :health_path),
      health_timeout_ms: map_value(worker, :health_timeout_ms),
      probe_interval_ms: map_value(worker, :probe_interval_ms),
      capabilities: map_value(worker, :capabilities, []),
      headers: map_value(worker, :headers, %{}),
      enabled: map_value(worker, :enabled, true),
      health_status: map_value(worker, :health_status, "healthy"),
      health_reason: map_value(worker, :health_reason),
      last_health_transition_at: map_value(worker, :last_health_transition_at),
      last_healthy_at: map_value(worker, :last_healthy_at),
      last_failure_at: map_value(worker, :last_failure_at),
      consecutive_failures: map_value(worker, :consecutive_failures, 0),
      recent_probe_results: map_value(worker, :recent_probe_results, []),
      flapping: map_value(worker, :flapping, false),
      flapping_transition_count: map_value(worker, :flapping_transition_count, 0),
      flapping_window_size: map_value(worker, :flapping_window_size, 0),
      alert_active: map_value(worker, :alert_active, false),
      alert_state: map_value(worker, :alert_state),
      alert_reason: map_value(worker, :alert_reason),
      metadata: map_value(worker, :metadata, %{})
    }
  end

  defp ensure_enabled(worker) do
    if map_value(worker, :enabled, true) do
      :ok
    else
      {:error, :worker_unavailable}
    end
  end

  defp ensure_healthy(worker) do
    if healthy_worker?(worker) do
      :ok
    else
      {:error, :worker_unhealthy}
    end
  end

  defp ensure_capability(_worker, nil), do: :ok

  defp ensure_capability(worker, requested_capability) do
    if requested_capability in map_value(worker, :capabilities, []) do
      :ok
    else
      {:error, :worker_capability_unmatched}
    end
  end

  defp ensure_http_adapter(worker) do
    adapter = map_value(worker, :adapter, "http")

    if adapter in @supported_http_adapters do
      :ok
    else
      {:error, {:unsupported_worker_adapter, adapter}}
    end
  end

  defp healthy_worker?(worker) do
    map_value(worker, :health_status, "healthy") == "healthy"
  end

  defp http_worker?(worker) do
    map_value(worker, :adapter, "http") in @supported_http_adapters
  end

  defp required_direct_worker_id!(attrs) do
    case present_string(attrs, :worker_id) do
      nil -> raise ArgumentError, "worker_id is required when endpoint_url is provided"
      worker_id -> worker_id
    end
  end

  defp requested_capability(attrs) do
    present_string(attrs, :required_capability) || present_string(attrs, :capability)
  end

  defp excluded_worker_ids(attrs) when is_map(attrs) do
    attrs
    |> map_value(:excluded_worker_ids, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_health_reason(nil), do: nil
  defp normalize_health_reason({:unsupported_worker_adapter, adapter}), do: "unsupported_worker_adapter:#{adapter}"
  defp normalize_health_reason({:http_status, status, _body}), do: "http_status_#{status}"
  defp normalize_health_reason({:transport_error, reason}), do: "transport_error:#{reason}"
  defp normalize_health_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_health_reason(reason) when is_binary(reason), do: reason
  defp normalize_health_reason(reason), do: inspect(reason)

  defp maybe_put_transition_timestamp(attrs, worker, now, target_status) do
    if map_value(worker, :health_status, "healthy") == target_status do
      attrs
    else
      Map.put(attrs, :last_health_transition_at, now)
    end
  end

  defp maybe_put_recent_probe_result(attrs, worker, status, reason, checked_at, opts) do
    if Keyword.get(opts, :record_probe_history, false) do
      history_limit = Keyword.get(opts, :probe_history_limit, 5)

      entry = %{
        "checked_at" => DateTime.to_iso8601(checked_at),
        "status" => status,
        "reason" => reason
      }

      history =
        worker
        |> map_value(:recent_probe_results, [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.take(max(history_limit - 1, 0))

      Map.put(attrs, :recent_probe_results, [entry | history])
    else
      attrs
    end
  end

  defp put_flapping_state(attrs, worker, opts) do
    recent_probe_results = Map.get(attrs, :recent_probe_results, map_value(worker, :recent_probe_results, []))

    flapping_metadata = derive_flapping_metadata(recent_probe_results, opts)

    attrs
    |> Map.put(:flapping, flapping_metadata.flapping)
    |> Map.put(:flapping_transition_count, flapping_metadata.flapping_transition_count)
    |> Map.put(:flapping_window_size, flapping_metadata.flapping_window_size)
  end

  defp put_alert_state(attrs, worker, opts) do
    worker_state =
      worker
      |> normalize_worker()
      |> Map.merge(attrs)

    alert_metadata = derive_alert_metadata(worker_state, opts)

    attrs
    |> Map.put(:alert_active, alert_metadata.alert_active)
    |> Map.put(:alert_state, alert_metadata.alert_state)
    |> Map.put(:alert_reason, alert_metadata.alert_reason)
  end

  defp derive_flapping_metadata(recent_probe_results, opts) do
    history =
      recent_probe_results
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    transition_count =
      history
      |> Enum.map(fn result -> Map.get(result, "status") || Map.get(result, :status) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [left, right] -> left != right end)

    window_size = length(history)
    threshold = Keyword.get(opts, :flapping_transition_threshold, @default_flapping_transition_threshold)

    %{
      flapping: window_size >= threshold + 1 and transition_count >= threshold,
      flapping_transition_count: transition_count,
      flapping_window_size: window_size
    }
  end

  defp derive_alert_metadata(worker_state, opts) do
    unhealthy_threshold =
      Keyword.get(opts, :worker_alert_failure_threshold, @default_unhealthy_alert_failure_threshold)

    override_state = Keyword.get(opts, :alert_override_state)
    override_reason = Keyword.get(opts, :alert_override_reason)

    cond do
      present_string(%{value: override_state}, :value) ->
        %{
          alert_active: true,
          alert_state: to_string(override_state),
          alert_reason: normalize_health_reason(override_reason)
        }

      map_value(worker_state, :flapping, false) ->
        %{
          alert_active: true,
          alert_state: "flapping",
          alert_reason: "status_transitions_threshold"
        }

      map_value(worker_state, :health_status, "healthy") != "healthy" and
          map_value(worker_state, :consecutive_failures, 0) >= unhealthy_threshold ->
        %{
          alert_active: true,
          alert_state: "unhealthy",
          alert_reason: map_value(worker_state, :health_reason) || "consecutive_failures_threshold"
        }

      true ->
        %{alert_active: false, alert_state: nil, alert_reason: nil}
    end
  end

  defp present_string(map, key) when is_map(map) do
    case map |> map_value(key) |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  defp map_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp actor_option(opts) do
    case Keyword.fetch(opts, :actor) do
      {:ok, actor} -> [actor: actor]
      :error -> []
    end
  end
end
