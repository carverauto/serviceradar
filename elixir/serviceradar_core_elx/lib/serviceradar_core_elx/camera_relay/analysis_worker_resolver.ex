defmodule ServiceRadarCoreElx.CameraRelay.AnalysisWorkerResolver do
  @moduledoc """
  Resolves registered camera analysis workers for relay-scoped dispatch.
  """

  alias ServiceRadar.Camera.AnalysisWorker

  @supported_http_adapters ["http"]

  defp resolve_registered_worker(resource, worker_id, requested_capability, opts) do
    case resource.get_by_worker_id(worker_id, actor_option(opts)) do
      {:ok, nil} ->
        nil

      {:ok, worker} ->
        with :ok <- ensure_enabled(worker),
             :ok <- ensure_capability(worker, requested_capability),
             :ok <- ensure_http_adapter(worker) do
          {:ok,
           worker
           |> normalize_worker()
           |> Map.put(:selection_mode, "worker_id")
           |> Map.put(:requested_capability, requested_capability)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp selection_request(attrs) do
    direct_endpoint_url = present_string(attrs, :endpoint_url)
    registered_worker_id = present_string(attrs, :registered_worker_id)

    fallback_worker_id =
      if is_nil(direct_endpoint_url), do: present_string(attrs, :worker_id)

    requested_capability = requested_capability(attrs)

    cond do
      is_binary(registered_worker_id) ->
        {:worker_id, registered_worker_id, requested_capability}

      is_binary(requested_capability) ->
        {:capability, requested_capability}

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

  def resolve_http_worker(attrs, opts) do
    resource = Keyword.get(opts, :resource, AnalysisWorker)

    case selection_request(attrs) do
      {:direct, worker} ->
        {:ok, Map.merge(worker, %{selection_mode: "direct", requested_capability: nil})}

      {:worker_id, worker_id, requested_capability} ->
        case resolve_registered_worker(resource, worker_id, requested_capability, opts) do
          nil -> {:error, :worker_not_found}
          other -> other
        end

      {:capability, requested_capability} ->
        resolve_by_capability(resource, requested_capability, opts)

      :error ->
        {:error, :worker_target_required}
    end
  end

  defp resolve_by_capability(resource, requested_capability, opts) do
    case resource.list_enabled(actor_option(opts)) do
      {:ok, workers} ->
        workers
        |> Enum.map(&normalize_worker/1)
        |> Enum.find(&(requested_capability in (&1.capabilities || [])))
        |> case do
          nil ->
            {:error, :worker_capability_unmatched}

          worker ->
            with :ok <- ensure_http_adapter(worker) do
              {:ok,
               worker
               |> Map.put(:selection_mode, "capability")
               |> Map.put(:requested_capability, requested_capability)}
            end
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

  defp required_direct_worker_id!(attrs) do
    case present_string(attrs, :worker_id) do
      nil -> raise ArgumentError, "worker_id is required when endpoint_url is provided"
      worker_id -> worker_id
    end
  end

  defp requested_capability(attrs) do
    present_string(attrs, :required_capability) || present_string(attrs, :capability)
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
