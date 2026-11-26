defmodule ServiceRadarWebNG.CameraVantageWorkers do
  @moduledoc """
  Ash-scoped read helper for Vantage ML worker registrations, queue lag, and
  active Ramp 1 (`camera_vlm`) vs Ramp 2 (`vantage.worker.v1`) routing status.

  All database queries run strictly via `Ash.read(query, scope: scope)` so
  resource RBAC policies are enforced on every caller (`catalog.view`,
  `settings.recording.view`).
  """

  alias ServiceRadar.Camera.VantageJob
  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Camera.VantageWorkerRegistration

  require Ash.Query

  @doc "Empty summary used during disconnected LiveView mounts before connected load."
  @spec default_summary() :: map()
  def default_summary do
    %{
      workers: [],
      online_count: 0,
      stale_count: 0,
      queue_lag: %{
        accessible?: true,
        pending_count: 0,
        dispatched_count: 0,
        oldest_pending_age_seconds: nil
      },
      routing_mode: :idle,
      pipelines: []
    }
  end

  @doc """
  Loads Vantage worker health, queue lag, and active Ramp 1 vs Ramp 2 routing
  status under the caller's RBAC `scope`.
  """
  @spec summary(map() | nil, keyword()) :: map()
  def summary(scope, opts \\ []) when is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    workers =
      scope
      |> load_workers(opts)
      |> Enum.map(&serialize_worker(&1, now))

    pipelines =
      scope
      |> load_pipelines(opts)
      |> Enum.map(&summarize_pipeline(&1, workers))

    queue_lag = load_queue_lag(scope, now, opts)

    online_count = Enum.count(workers, & &1.online?)
    stale_count = Enum.count(workers, & &1.stale?)

    %{
      workers: workers,
      online_count: online_count,
      stale_count: stale_count,
      queue_lag: queue_lag,
      routing_mode: infer_routing_mode(pipelines, workers),
      pipelines: pipelines
    }
  end

  defp load_workers(scope, opts) do
    cond do
      Keyword.has_key?(opts, :workers) ->
        List.wrap(Keyword.get(opts, :workers, []))

      is_function(opts[:workers_loader], 1) ->
        normalize_list_result(opts[:workers_loader].(scope))

      is_nil(scope) ->
        []

      true ->
        VantageWorkerRegistration
        |> Ash.Query.for_read(:read, %{}, scope: scope)
        |> Ash.Query.sort(worker_id: :asc)
        |> Ash.read(scope: scope)
        |> normalize_list_result()
    end
  end

  defp load_pipelines(scope, opts) do
    cond do
      Keyword.has_key?(opts, :pipelines) ->
        List.wrap(Keyword.get(opts, :pipelines, []))

      is_function(opts[:pipelines_loader], 1) ->
        normalize_list_result(opts[:pipelines_loader].(scope))

      is_nil(scope) ->
        []

      true ->
        VantagePipeline
        |> Ash.Query.for_read(:read, %{}, scope: scope)
        |> Ash.Query.filter(enabled == true)
        |> Ash.Query.sort(pipeline_id: :asc)
        |> Ash.read(scope: scope)
        |> normalize_list_result()
    end
  end

  defp load_queue_lag(scope, now, opts) do
    cond do
      Keyword.has_key?(opts, :jobs) ->
        summarize_queue_lag({:ok, List.wrap(Keyword.get(opts, :jobs, []))}, now)

      is_function(opts[:jobs_loader], 1) ->
        summarize_queue_lag(opts[:jobs_loader].(scope), now)

      is_nil(scope) ->
        summarize_queue_lag({:ok, []}, now)

      true ->
        load_db_queue_lag(scope, now)
    end
  end

  defp load_db_queue_lag(scope, now) do
    pending_query =
      VantageJob
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(state == :pending)

    dispatched_query =
      VantageJob
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(state == :dispatched)

    oldest_pending_query =
      pending_query
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(1)

    with {:ok, pending_count} <- Ash.count(pending_query, scope: scope),
         {:ok, dispatched_count} <- Ash.count(dispatched_query, scope: scope),
         {:ok, oldest_jobs} <- Ash.read(oldest_pending_query, scope: scope) do
      %{
        accessible?: true,
        pending_count: pending_count,
        dispatched_count: dispatched_count,
        oldest_pending_age_seconds: oldest_pending_age_seconds(oldest_jobs, now)
      }
    else
      _forbidden_or_error ->
        %{
          accessible?: false,
          pending_count: 0,
          dispatched_count: 0,
          oldest_pending_age_seconds: nil
        }
    end
  end

  defp summarize_queue_lag({:ok, jobs}, now) when is_list(jobs) do
    pending = Enum.filter(jobs, &(fetch_val(&1, :state) in [:pending, "pending"]))
    dispatched = Enum.filter(jobs, &(fetch_val(&1, :state) in [:dispatched, "dispatched"]))

    %{
      accessible?: true,
      pending_count: length(pending),
      dispatched_count: length(dispatched),
      oldest_pending_age_seconds: oldest_pending_age_seconds(pending, now)
    }
  end

  defp summarize_queue_lag(_forbidden_or_error, _now) do
    %{
      accessible?: false,
      pending_count: 0,
      dispatched_count: 0,
      oldest_pending_age_seconds: nil
    }
  end

  defp oldest_pending_age_seconds(pending_jobs, now) do
    pending_jobs
    |> Enum.map(&fetch_val(&1, :inserted_at))
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.min(DateTime, fn -> nil end)
    |> case do
      %DateTime{} = dt -> max(0, DateTime.diff(now, dt, :second))
      nil -> nil
    end
  end

  defp serialize_worker(worker, now) do
    expires_at = fetch_val(worker, :expires_at)
    health = normalize_atom_str(fetch_val(worker, :health), "unknown")
    active_jobs = int_or_zero(fetch_val(worker, :active_jobs))
    max_concurrency = max(1, int_or_zero(fetch_val(worker, :max_concurrency)))

    stale? =
      case expires_at do
        %DateTime{} = dt -> DateTime.compare(dt, now) != :gt
        _ -> true
      end

    online? = not stale? and health in ["ready", "degraded"]

    %{
      worker_id: to_string(fetch_val(worker, :worker_id) || ""),
      worker_kind: normalize_atom_str(fetch_val(worker, :worker_kind), "external_rust"),
      protocol_version: to_string(fetch_val(worker, :protocol_version) || "vantage.worker.v1"),
      capabilities: Enum.map(List.wrap(fetch_val(worker, :capabilities)), &to_string/1),
      supported_source_modes: Enum.map(List.wrap(fetch_val(worker, :supported_source_modes)), &to_string/1),
      execution_backend: to_string(fetch_val(worker, :execution_backend) || "unknown"),
      architecture: to_string(fetch_val(worker, :architecture) || "unknown"),
      model_id: to_string(fetch_val(worker, :model_id) || ""),
      model_version: to_string(fetch_val(worker, :model_version) || ""),
      active_jobs: active_jobs,
      max_concurrency: max_concurrency,
      saturated?: active_jobs >= max_concurrency,
      health: health,
      last_heartbeat_at: fetch_val(worker, :last_heartbeat_at),
      expires_at: expires_at,
      online?: online?,
      stale?: stale?
    }
  end

  defp summarize_pipeline(pipeline, workers) do
    runner = normalize_atom_str(fetch_val(pipeline, :runner), "camera_vlm")
    capability = fetch_val(pipeline, :capability)
    fallback_runner = fetch_val(pipeline, :fallback_runner)
    source_mode = normalize_atom_str(fetch_val(pipeline, :source_mode), "recorded_block")

    eligible_count =
      Enum.count(workers, fn w ->
        w.online? and w.health == "ready" and not w.saturated? and
          is_binary(capability) and capability in w.capabilities and
          source_mode in w.supported_source_modes
      end)

    active_route =
      cond do
        runner == "camera_vlm" -> :camera_vlm
        eligible_count > 0 -> :ramp_2
        fallback_runner == "camera_vlm" and source_mode == "recorded_block" -> :ramp_1_fallback
        true -> :held
      end

    %{
      pipeline_id: to_string(fetch_val(pipeline, :pipeline_id) || ""),
      version: to_string(fetch_val(pipeline, :version) || ""),
      runner: runner,
      capability: capability,
      fallback_runner: fallback_runner,
      source_mode: source_mode,
      active_route: active_route,
      worker_count: eligible_count
    }
  end

  defp infer_routing_mode([], workers) do
    if Enum.any?(workers, & &1.online?), do: :ramp_2, else: :idle
  end

  defp infer_routing_mode(pipelines, _workers) do
    routes = MapSet.new(pipelines, & &1.active_route)

    cond do
      MapSet.member?(routes, :ramp_2) and
          (MapSet.member?(routes, :ramp_1_fallback) or MapSet.member?(routes, :camera_vlm)) ->
        :mixed

      MapSet.member?(routes, :ramp_2) ->
        :ramp_2

      MapSet.member?(routes, :ramp_1_fallback) ->
        :ramp_1_fallback

      MapSet.member?(routes, :camera_vlm) ->
        :ramp_1_fallback

      MapSet.member?(routes, :held) ->
        :held

      true ->
        :idle
    end
  end

  defp normalize_list_result({:ok, list}) when is_list(list), do: list
  defp normalize_list_result(list) when is_list(list), do: list
  defp normalize_list_result(_), do: []

  defp normalize_atom_str(nil, default), do: default
  defp normalize_atom_str(val, _default) when is_atom(val), do: Atom.to_string(val)
  defp normalize_atom_str(val, _default) when is_binary(val), do: val
  defp normalize_atom_str(_, default), do: default

  defp int_or_zero(v) when is_integer(v), do: v
  defp int_or_zero(_), do: 0

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
