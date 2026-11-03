defmodule ServiceRadar.NetworkDiscovery.TopologyProjectionWorker do
  @moduledoc """
  Projects committed mapper interface and topology evidence into the topology
  graph (AGE when written, Dgraph when written) outside the result-ingestion
  lane.

  `MapperResultsIngestor` commits the authoritative CNPG rows inside its lane
  worker and then calls `enqueue/2` with the records it would have projected.
  The graph projection, which makes Dgraph round trips and may run pruning and
  the canonical rebuild, no longer counts against the lane's worker budget, so
  a slow graph backend cannot time a mapper result out and lose it.

  ## Projection lag

  The graph trails CNPG by the job's queue wait plus its run time. Topology
  reads (Atlas, the topology views, the causal hydrator) read the graph, so
  they show a mapper result that much later than device and interface reads
  that come from CNPG. Both parts are reported on the `topology_projection`
  ingestion runtime-metrics lane as `queue_wait_ms` and `duration_ms`.

  ## Ordering and coalescing

  A job is keyed by its kind and its scope: the sorted set of devices the
  result reports (the local devices of a topology report). For one scope:

    * a newer result replaces the input of a job that has not started, so a
      backlog collapses to the latest result (`coalesced`);
    * a job that starts while an earlier job for the scope is still executing
      waits for it (`{:snooze, _}`);
    * a job that starts while a later job for the scope exists is superseded
      and cancelled without projecting (`cancellation`).

  Results therefore apply in arrival order, which is run order: the lane
  admits one result per agent at a time and mapper results are never
  redelivered. Every write is an idempotent upsert, so a retry or a repeat is
  harmless.

  An `executing` job older than this worker's timeout is treated as orphaned
  (Oban would have killed a live one), so a node that dies mid-projection does
  not block its scope until Lifeline rescues the row.

  ## Failure

  A failed projection is logged, counted as `not_accepted` on the
  `topology_projection` lane, reported as an Oban job exception, and retried
  with backoff. A projection that exhausts its attempts is also counted as
  `failed`. The next mapper result for the scope enqueues a fresh projection.
  """

  use Oban.Worker,
    queue: :topology_projection,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:kind, :scope],
      states: [:available, :scheduled, :retryable]
    ]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @lane :topology_projection
  @timeout_ms to_timeout(minute: 10)
  # A live job is killed at its timeout; one still `executing` past this is
  # orphaned by a node that went away.
  @orphaned_after_ms @timeout_ms + to_timeout(minute: 1)
  @wait_seconds 5
  @pending_states ~w(available scheduled retryable)
  @replace [available: [:args], scheduled: [:args], retryable: [:args]]

  @type kind :: :interfaces | :links

  @doc """
  Schedules the graph projection of mapper `records` already committed to
  CNPG. Never fails the caller: CNPG holds the result either way. A job that
  cannot be enqueued is logged and counted as `failed`.
  """
  @spec enqueue(kind(), [map()]) :: :ok
  def enqueue(_kind, []), do: :ok

  def enqueue(kind, records) when kind in [:interfaces, :links] and is_list(records) do
    inputs = Enum.map(records, &projection_input(kind, &1))

    args = %{
      kind: Atom.to_string(kind),
      scope: scope(kind, inputs),
      enqueued_at: DateTime.to_iso8601(DateTime.utc_now()),
      records: inputs
    }

    case args |> new(replace: @replace) |> ObanSupport.safe_insert() do
      {:ok, %Oban.Job{conflict?: true}} ->
        RuntimeMetrics.record(@lane, :coalesced, %{})

      {:ok, %Oban.Job{}} ->
        RuntimeMetrics.record(@lane, :admitted, %{})

      {:error, reason} ->
        RuntimeMetrics.record(@lane, :failed, %{})

        Logger.error(
          "Topology projection could not be scheduled; the graph will not reflect this " <>
            "mapper result until the next one",
          kind: kind,
          records: length(records),
          reason: inspect(reason)
        )
    end

    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: @timeout_ms

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "records" => records}} = job)
      when kind in ["interfaces", "links"] and is_list(records) do
    case turn(job) do
      :superseded ->
        RuntimeMetrics.record(@lane, :cancellation, %{})
        {:cancel, :superseded}

      :wait ->
        {:snooze, @wait_seconds}

      :apply ->
        project(kind, records, job)
    end
  end

  defp project(kind, records, job) do
    started = System.monotonic_time(:millisecond)

    result =
      case kind do
        "interfaces" -> TopologyGraph.upsert_interfaces(records)
        "links" -> TopologyGraph.upsert_links(records)
      end

    measurements = %{
      duration_ms: System.monotonic_time(:millisecond) - started,
      queue_wait_ms: queue_wait_ms(job)
    }

    case result do
      :ok ->
        RuntimeMetrics.record(@lane, :completion, Map.put(measurements, :outcome, :accepted))
        :ok

      {:error, reason} ->
        RuntimeMetrics.record(@lane, :completion, Map.put(measurements, :outcome, :not_accepted))
        if job.attempt >= job.max_attempts, do: RuntimeMetrics.record(@lane, :failed, %{})

        Logger.warning("Topology projection failed; the graph lags CNPG until it succeeds",
          kind: kind,
          attempt: job.attempt,
          max_attempts: job.max_attempts,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Decides from the other incomplete jobs for this scope whether this one may
  # project now. Job ids order arrivals.
  defp turn(%Oban.Job{id: id, args: %{"kind" => kind, "scope" => scope}}) do
    orphaned_before = DateTime.add(DateTime.utc_now(), -@orphaned_after_ms, :millisecond)

    siblings =
      Repo.all(
        from(j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(__MODULE__) and
              j.queue == ^Atom.to_string(@lane) and j.id != ^id and
              fragment("? ->> 'kind'", j.args) == ^kind and
              fragment("? ->> 'scope'", j.args) == ^scope and
              (j.state in @pending_states or
                 (j.state == "executing" and j.attempted_at > ^orphaned_before)),
          select: {j.id, j.state}
        ),
        prefix: ObanSupport.prefix()
      )

    cond do
      Enum.any?(siblings, fn {sibling, _state} -> sibling > id end) -> :superseded
      Enum.any?(siblings, &match?({_sibling, "executing"}, &1)) -> :wait
      true -> :apply
    end
  end

  defp queue_wait_ms(%Oban.Job{args: %{"enqueued_at" => enqueued_at}, attempted_at: attempted}) do
    with %DateTime{} <- attempted,
         {:ok, enqueued, _offset} <- DateTime.from_iso8601(enqueued_at) do
      max(DateTime.diff(attempted, enqueued, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp queue_wait_ms(_job), do: nil

  defp projection_input(:interfaces, record), do: TopologyGraph.interface_projection_input(record)
  defp projection_input(:links, record), do: TopologyGraph.link_projection_input(record)

  # Stable across nodes and releases, unlike :erlang.phash2/1.
  defp scope(kind, inputs) do
    key = if kind == :interfaces, do: :device_id, else: :local_device_id

    ids =
      inputs
      |> Enum.map(&Map.get(&1, key))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    :sha256
    |> :crypto.hash(Enum.join(ids, "\n"))
    |> Base.encode16(case: :lower)
  end
end
