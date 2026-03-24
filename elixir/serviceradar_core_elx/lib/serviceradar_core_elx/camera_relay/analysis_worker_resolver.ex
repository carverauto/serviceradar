defmodule ServiceRadarCoreElx.CameraRelay.AnalysisWorkerResolver do
  @moduledoc """
  Resolves registered camera analysis workers for relay-scoped dispatch.
  """

  alias ServiceRadar.Camera.AnalysisWorker

  @supported_http_adapters ["http"]

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
         {:ok, updated_worker} <-
           resource.update_worker(
             worker,
             %{
               health_status: "healthy",
               health_reason: nil,
               last_health_transition_at: now,
               last_healthy_at: now,
               consecutive_failures: 0
             },
             actor_option(opts)
           ) do
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
         {:ok, updated_worker} <-
           resource.update_worker(
             worker,
             %{
               health_status: "unhealthy",
               health_reason: health_reason,
               last_health_transition_at: now,
               last_failure_at: now,
               consecutive_failures: map_value(worker, :consecutive_failures, 0) + 1
             },
             actor_option(opts)
           ) do
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
      capabilities: map_value(worker, :capabilities, []),
      headers: map_value(worker, :headers, %{}),
      enabled: map_value(worker, :enabled, true),
      health_status: map_value(worker, :health_status, "healthy"),
      health_reason: map_value(worker, :health_reason),
      last_health_transition_at: map_value(worker, :last_health_transition_at),
      last_healthy_at: map_value(worker, :last_healthy_at),
      last_failure_at: map_value(worker, :last_failure_at),
      consecutive_failures: map_value(worker, :consecutive_failures, 0),
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

  defp normalize_health_reason({:unsupported_worker_adapter, adapter}), do: "unsupported_worker_adapter:#{adapter}"

  defp normalize_health_reason({:http_status, status, _body}), do: "http_status_#{status}"
  defp normalize_health_reason({:transport_error, reason}), do: "transport_error:#{reason}"
  defp normalize_health_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_health_reason(reason) when is_binary(reason), do: reason
  defp normalize_health_reason(reason), do: inspect(reason)

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
