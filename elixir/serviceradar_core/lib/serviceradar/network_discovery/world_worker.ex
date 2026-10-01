defmodule ServiceRadar.NetworkDiscovery.WorldWorker do
  @moduledoc "Builds persistent topology worlds off the request path from one canonical Dgraph snapshot."

  use Oban.Worker,
    queue: :topology_world,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:mode], states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dgraph
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.NetworkDiscovery.World
  alias ServiceRadar.NetworkDiscovery.WorldInventory
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadar.TopologyAtlas

  @reconcile_seconds 900
  @delta_operations [
    :insert_positions,
    :update_positions,
    :activate_device_ids,
    :deactivate_device_ids,
    :upsert_relations,
    :deactivate_relation_ids
  ]

  @doc "Ensures a bounded reconciliation cadence; this reads job metadata, never the graph."
  def ensure_scheduled do
    with {:ok, _url} <- Dgraph.url() do
      if ObanSupport.available?() do
        case incomplete_reconcile() do
          nil ->
            enqueue_reconcile(schedule_in: next_reconcile_delay())

          %{state: "scheduled"} ->
            if pending_request?(last_completed_reconcile()) do
              enqueue_reconcile()
            else
              {:ok, :already_scheduled}
            end

          _job ->
            {:ok, :already_scheduled}
        end
      else
        {:error, :oban_unavailable}
      end
    end
  end

  @doc "Coalesces canonical rebuilds and advances a pending reconciliation."
  def enqueue_reconcile(opts \\ []) do
    opts =
      opts
      |> Keyword.put(:meta, %{"request_id" => Ash.UUID.generate()})
      |> Keyword.put(:replace, executing: [:meta], scheduled: [:meta, :scheduled_at])

    %{"mode" => "reconcile", "layout_version" => Ash.UUID.generate()}
    |> new(opts)
    |> ObanSupport.safe_insert()
  end

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => mode, "layout_version" => version}} = job)
      when mode in ["reconcile", "relayout"] and is_binary(version) do
    with_result =
    with {:ok, _job} <- record_request(job),
           {:ok, state} <- prepare(mode, version),
           :ok <- HypervisorEnrichmentIngestor.reconcile_hosted_topology(),
           {:ok, graph} <- TopologyAtlas.read_graph(),
           {:ok, builder} <-
             WorldInventory.stream(state.builder, fn rows, builder ->
               with :ok <- TopologyAtlas.add_inventory(builder, rows), do: {:ok, builder}
             end),
           {:ok, candidate} <- TopologyAtlas.reconcile(builder, graph),
           {:ok, info} <- TopologyAtlas.candidate_info(candidate) do
        publish(state, candidate, info)
      end

    job_result(with_result)
  end

  def perform(_job), do: {:cancel, :invalid_world_job}

  defp record_request(%Oban.Job{args: %{"mode" => "reconcile"}} = job) do
    Oban.update_job(job.id, %{
      args: Map.put(job.args, "observed_request", Map.get(job.meta, "request_id"))
    })
  end

  defp record_request(job), do: {:ok, job}

  defp prepare("reconcile", version) do
    case World.active_manifest(scope()) do
      {:ok, manifest} ->
        if manifest.algorithm_version == TopologyAtlas.algorithm_version() do
          with {:ok, state} <- World.stream_active(%{}, &load_previous/2) do
            {:ok, Map.put(state, :mode, :incremental)}
          end
        else
          # Keep the accepted world available until its replacement is completely
          # staged. The generation fence rejects a competing publication.
          fresh_state(version, manifest.generation, :relayout)
        end

      {:error, :not_ready} ->
        fresh_state(version, 0, :initial)

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare("relayout", version) do
    case World.active_manifest(scope()) do
      {:ok, manifest} -> fresh_state(version, manifest.generation, :relayout)
      {:error, :not_ready} -> fresh_state(version, 0, :relayout)
      {:error, _reason} = error -> error
    end
  end

  defp fresh_state(version, generation, mode) do
    with {:ok, builder} <- TopologyAtlas.new_builder(version, 16) do
      {:ok, %{builder: builder, generation: generation, layout_version: version, mode: mode}}
    end
  end

  defp load_previous({:manifest, manifest}, state) do
    with {:ok, builder} <- TopologyAtlas.new_builder(manifest.layout_version, manifest.zmax) do
      {:ok,
       Map.merge(state, %{builder: builder, manifest: manifest, generation: manifest.generation})}
    end
  end

  defp load_previous({:positions, rows}, state) do
    with :ok <- TopologyAtlas.add_positions(state.builder, rows), do: {:ok, state}
  end

  defp load_previous({:relations, rows}, state) do
    with :ok <- TopologyAtlas.add_relations(state.builder, rows), do: {:ok, state}
  end

  defp publish(state, candidate, info) do
    publish_candidate(state, candidate, normalize_publication(info))
  end

  defp publish_candidate(%{mode: :incremental, manifest: previous} = state, candidate, info) do
    if publication_identity(previous) == publication_identity(info) do
      :ok
    else
      delta =
        @delta_operations
        |> Map.new(&{&1, pages(candidate, &1)})
        |> Map.merge(
          Map.take(info, [:source_digest, :node_count, :relation_count, :pipeline_stats])
        )

      World.publish_delta(state.generation, delta)
    end
  end

  defp publish_candidate(state, candidate, info) do
    with :ok <-
           World.stage_candidate(
             state.layout_version,
             info,
             pages(candidate, :positions),
             pages(candidate, :relations)
           ) do
      # A losing initial build is unpublished. Its terminal job and old stage
      # become eligible for bounded retention; never delete a full world here.
      World.activate_relayout(state.generation, state.layout_version)
    end
  end

  defp normalize_publication(info) do
    Map.put(info, :pipeline_stats, string_stats(Map.get(info, :pipeline_stats)))
  end

  defp publication_identity(info) do
    info
    |> Map.take([:source_digest, :node_count, :relation_count])
    |> Map.put(:pipeline_stats, string_stats(Map.get(info, :pipeline_stats)))
  end

  defp string_stats(stats) when is_map(stats) do
    Map.new(for {key, value} <- stats, is_integer(value), do: {to_string(key), value})
  end

  defp string_stats(_), do: %{}

  defp pages(candidate, operation) do
    Stream.resource(
      fn -> 0 end,
      fn
        nil ->
          {:halt, nil}

        cursor ->
          case page(candidate, operation, cursor) do
            {:ok, %{items: items, next_cursor: next_cursor}} -> {items, next_cursor}
            {:error, _reason} -> raise "Native topology candidate page could not be read"
          end
      end,
      fn _cursor -> :ok end
    )
  end

  defp page(candidate, :positions, cursor),
    do: TopologyAtlas.positions_page(candidate, cursor, @batch_size)

  defp page(candidate, :relations, cursor),
    do: TopologyAtlas.relations_page(candidate, cursor, @batch_size)

  defp page(candidate, operation, cursor),
    do: TopologyAtlas.delta_page(candidate, operation, cursor, @batch_size)

  defp job_result(:ok), do: :ok
  defp job_result({:ok, _manifest}), do: :ok
  defp job_result({:error, :layout_already_published}), do: :ok
  defp job_result({:error, :stale_generation}), do: {:snooze, 5}
  defp job_result({:error, _reason} = error), do: error

  defp incomplete_reconcile do
    query =
      from(job in Oban.Job,
        where: job.worker == ^Oban.Worker.to_string(__MODULE__),
        where: fragment("? ->> 'mode'", job.args) == "reconcile",
        where: job.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.one(query, prefix: ObanSupport.prefix())
  end

  defp next_reconcile_delay do
    case last_completed_reconcile() do
      nil ->
        0

      job ->
        if pending_request?(job) do
          0
        else
          max(
            @reconcile_seconds - DateTime.diff(DateTime.utc_now(), job.completed_at, :second),
            0
          )
        end
    end
  end

  defp last_completed_reconcile do
    query =
      from(job in Oban.Job,
        where: job.worker == ^Oban.Worker.to_string(__MODULE__),
        where: fragment("? ->> 'mode'", job.args) == "reconcile",
        where: job.state == "completed",
        order_by: [desc: job.completed_at, desc: job.id],
        limit: 1
      )

    Repo.one(query, prefix: ObanSupport.prefix())
  end

  defp pending_request?(nil), do: false

  defp pending_request?(job),
    do: Map.get(job.meta, "request_id") != Map.get(job.args, "observed_request")

  defp scope, do: %{actor: SystemActor.system(:topology_world)}
end
