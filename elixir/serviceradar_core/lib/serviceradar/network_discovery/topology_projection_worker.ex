defmodule ServiceRadar.NetworkDiscovery.TopologyProjectionWorker do
  @moduledoc """
  Projects committed mapper interface and topology evidence into the topology
  graph (AGE when written, Dgraph when written) outside the result-ingestion
  lane.

  `MapperResultsIngestor` commits the authoritative CNPG rows inside its lane
  worker and then calls `enqueue/2` with the records it just committed. Each
  job carries one device id and nothing else. The graph projection, which
  makes Dgraph round trips and may run pruning and the canonical rebuild, no
  longer counts against the lane's worker budget, so a slow graph backend
  cannot time a mapper result out and lose it.

  ## Projection lag

  The graph trails CNPG by the job's queue wait plus its run time. Topology
  reads (Atlas, the topology views, the causal hydrator) read the graph, so
  they show a mapper result that much later than device and interface reads
  that come from CNPG. Both parts are reported on the `topology_projection`
  ingestion runtime-metrics lane as `queue_wait_ms` and `duration_ms`.

  ## What a job applies

  At perform the worker reads the current committed rows for that one device
  and projects them: discovered interfaces (including their aliases) and
  mapper topology links where the device is local. The write is the same
  batched idempotent replace the inline path used, and it does not write
  another device's interfaces or links. A job does not carry the result that
  enqueued it, so a retry, including one that runs after a newer job for the
  device has already completed, applies whatever CNPG holds at that moment.

  Uniqueness on the device id is only coalescing. A newer result for that
  device replaces a job that has not started, so a pending backlog collapses
  to one run per device. A job that starts while another job for the same
  device that started before it is still executing waits for it, including a
  retry of an older job that starts while a newer one runs. An `executing` job
  older than this worker's timeout is treated as orphaned, so a node that dies
  mid-projection does not block the device until Lifeline rescues the row. The
  rescued job reads CNPG again.

  ## Failure

  A failed projection is logged, counted as `not_accepted` on the
  `topology_projection` lane, reported as an Oban job exception, and retried
  with backoff. A projection that exhausts its attempts is also counted as
  `failed`. The next mapper result for the device enqueues a fresh projection.
  """

  use Oban.Worker,
    queue: :topology_projection,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:device_id],
      states: [:available, :scheduled, :retryable]
    ]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @lane :topology_projection
  @timeout_ms to_timeout(minute: 10)
  # A live job is killed at its timeout; one still `executing` past this is
  # orphaned by a node that went away.
  @orphaned_after_ms @timeout_ms + to_timeout(minute: 1)
  @wait_seconds 5
  @replace [available: [:args], scheduled: [:args], retryable: [:args]]

  @type kind :: :interfaces | :links

  @doc """
  Schedules one projection job per device named by mapper `records` already
  committed to CNPG. Never fails the caller: CNPG holds the result either way.
  A job that cannot be enqueued is logged and counted as `failed`.
  """
  @spec enqueue(kind(), [map()]) :: :ok
  def enqueue(_kind, []), do: :ok

  def enqueue(kind, records) when kind in [:interfaces, :links] and is_list(records) do
    kind
    |> device_ids(records)
    |> Enum.each(&enqueue_device/1)

    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: @timeout_ms

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"device_id" => device_id}} = job) when is_binary(device_id) do
    case turn(job) do
      :wait ->
        {:snooze, @wait_seconds}

      :apply ->
        project(device_id, job)
    end
  end

  defp enqueue_device(device_id) do
    args = %{
      device_id: device_id,
      enqueued_at: DateTime.to_iso8601(DateTime.utc_now())
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
            "device until the next mapper result",
          device_id: device_id,
          reason: inspect(reason)
        )
    end
  end

  defp project(device_id, job) do
    started = System.monotonic_time(:millisecond)

    result =
      with :ok <- device_id |> load_interfaces() |> TopologyGraph.upsert_interfaces() do
        device_id |> load_links() |> TopologyGraph.upsert_links()
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
          device_id: device_id,
          attempt: job.attempt,
          max_attempts: job.max_attempts,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Another run for this device that started first may still be writing the
  # rows it read. Wait until it finishes, then read CNPG again. Runs are ordered
  # by when they started, then by id, so a retry of an older job that starts
  # while a newer one executes waits for it as well.
  defp turn(%Oban.Job{id: id, args: %{"device_id" => device_id}} = job) do
    now = DateTime.utc_now()
    started = job.attempted_at || now
    orphaned_before = DateTime.add(now, -@orphaned_after_ms, :millisecond)

    blocking =
      Repo.exists?(
        from(j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(__MODULE__) and
              j.queue == ^Atom.to_string(@lane) and j.id != ^id and
              j.state == "executing" and j.attempted_at > ^orphaned_before and
              (j.attempted_at < ^started or (j.attempted_at == ^started and j.id < ^id)) and
              fragment("? ->> 'device_id'", j.args) == ^device_id
        ),
        prefix: ObanSupport.prefix()
      )

    if blocking, do: :wait, else: :apply
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

  defp load_interfaces(device_id) do
    Repo.all(
      from(i in Interface,
        where: i.device_id == ^device_id,
        select: %{
          device_id: i.device_id,
          if_name: i.if_name,
          if_index: i.if_index,
          if_descr: i.if_descr,
          if_alias: i.if_alias,
          if_phys_address: i.if_phys_address,
          ip_addresses: i.ip_addresses
        }
      )
    )
  end

  defp load_links(device_id) do
    Repo.all(
      from(l in TopologyLink,
        where: l.local_device_id == ^device_id,
        order_by: [asc_nulls_first: l.timestamp],
        select: %{
          timestamp: l.timestamp,
          protocol: l.protocol,
          local_device_ip: l.local_device_ip,
          local_device_id: l.local_device_id,
          local_if_index: l.local_if_index,
          local_if_name: l.local_if_name,
          neighbor_device_id: l.neighbor_device_id,
          neighbor_chassis_id: l.neighbor_chassis_id,
          neighbor_port_id: l.neighbor_port_id,
          neighbor_port_descr: l.neighbor_port_descr,
          neighbor_system_name: l.neighbor_system_name,
          neighbor_mgmt_addr: l.neighbor_mgmt_addr,
          metadata: l.metadata
        }
      )
    )
  end

  defp device_ids(kind, records) do
    key = if kind == :interfaces, do: :device_id, else: :local_device_id

    records
    |> Enum.map(&record_value(&1, key))
    |> normalize_device_ids()
  end

  defp record_value(record, key) when is_map(record) do
    Map.get(record, key) || Map.get(record, Atom.to_string(key))
  end

  defp record_value(_record, _key), do: nil

  defp normalize_device_ids(ids) do
    ids
    |> Enum.flat_map(fn
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> []
          trimmed -> [trimmed]
        end

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
