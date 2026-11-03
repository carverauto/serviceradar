defmodule ServiceRadar.NetworkDiscovery.TopologyProjectionWorker do
  @moduledoc """
  Projects committed mapper interface and topology evidence into the topology
  graph (AGE when written, Dgraph when written) outside the result-ingestion
  lane.

  `MapperResultsIngestor` commits the authoritative CNPG rows inside its lane
  worker and then calls `enqueue/2` with the records it just committed. The
  job carries the projection kind and the device scope only. The graph
  projection, which makes Dgraph round trips and may run pruning and the
  canonical rebuild, no longer counts against the lane's worker budget, so a
  slow graph backend cannot time a mapper result out and lose it.

  ## Projection lag

  The graph trails CNPG by the job's queue wait plus its run time. Topology
  reads (Atlas, the topology views, the causal hydrator) read the graph, so
  they show a mapper result that much later than device and interface reads
  that come from CNPG. Both parts are reported on the `topology_projection`
  ingestion runtime-metrics lane as `queue_wait_ms` and `duration_ms`.

  ## What a job applies

  At perform the worker reads the current committed rows for the job's devices
  and projects those: discovered interfaces (including their aliases) or
  mapper topology links. The write is the same batched idempotent replace the
  inline path used. A job does not carry the result that enqueued it, so a
  retry, including one that runs after a newer job for the scope has already
  completed, applies whatever CNPG holds at that moment.

  Uniqueness on kind and scope is only coalescing. A newer result replaces a
  job that has not started, so a pending backlog collapses to one run. A job
  that starts while an earlier job for the scope is still executing waits for
  it. An `executing` job older than this worker's timeout is treated as
  orphaned, so a node that dies mid-projection does not block its scope until
  Lifeline rescues the row. The rescued job reads CNPG again.

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
  Schedules a projection of the devices named by mapper `records` already
  committed to CNPG. Never fails the caller: CNPG holds the result either way.
  A job that cannot be enqueued is logged and counted as `failed`.
  """
  @spec enqueue(kind(), [map()]) :: :ok
  def enqueue(_kind, []), do: :ok

  def enqueue(kind, records) when kind in [:interfaces, :links] and is_list(records) do
    device_ids = scope_device_ids(kind, records)

    args = %{
      kind: Atom.to_string(kind),
      scope: scope(device_ids),
      device_ids: device_ids,
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
  def perform(%Oban.Job{args: %{"kind" => kind} = args} = job)
      when kind in ["interfaces", "links"] do
    case turn(job) do
      :wait ->
        {:snooze, @wait_seconds}

      :apply ->
        project(kind, device_ids_from_args(args), job)
    end
  end

  defp project(kind, device_ids, job) do
    started = System.monotonic_time(:millisecond)

    result =
      case kind do
        "interfaces" -> device_ids |> load_interfaces() |> TopologyGraph.upsert_interfaces()
        "links" -> device_ids |> load_links() |> TopologyGraph.upsert_links()
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

  # An earlier live attempt may have read CNPG before the rows this job was
  # enqueued for were committed. Wait until it finishes, then read again.
  # A later or already-finished job is not a reason to skip: this attempt
  # reads the current rows and replaces the scope with them.
  defp turn(%Oban.Job{id: id, args: %{"kind" => kind, "scope" => scope}}) do
    orphaned_before = DateTime.add(DateTime.utc_now(), -@orphaned_after_ms, :millisecond)

    blocking =
      Repo.exists?(
        from(j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(__MODULE__) and
              j.queue == ^Atom.to_string(@lane) and j.id < ^id and
              j.state == "executing" and j.attempted_at > ^orphaned_before and
              fragment("? ->> 'kind'", j.args) == ^kind and
              fragment("? ->> 'scope'", j.args) == ^scope
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

  defp load_interfaces([]), do: []

  defp load_interfaces(device_ids) do
    Repo.all(
      from(i in Interface,
        where: i.device_id in ^device_ids,
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

  defp load_links([]), do: []

  defp load_links(device_ids) do
    Repo.all(
      from(l in TopologyLink,
        where: l.local_device_id in ^device_ids,
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

  # Jobs inserted before device_ids was the identity still name their devices
  # on each stored record. The record body is not projected.
  defp device_ids_from_args(%{"device_ids" => ids}) when is_list(ids) do
    normalize_device_ids(ids)
  end

  defp device_ids_from_args(%{"kind" => kind, "records" => records}) when is_list(records) do
    key = if kind == "interfaces", do: "device_id", else: "local_device_id"

    records
    |> Enum.map(&record_device_id(&1, key))
    |> normalize_device_ids()
  end

  defp device_ids_from_args(_args), do: []

  defp record_device_id(record, key) when is_map(record), do: Map.get(record, key)
  defp record_device_id(_record, _key), do: nil

  defp scope_device_ids(kind, records) do
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

  # Stable across nodes and releases, unlike :erlang.phash2/1.
  defp scope(device_ids) do
    :sha256
    |> :crypto.hash(Enum.join(device_ids, "\n"))
    |> Base.encode16(case: :lower)
  end
end
