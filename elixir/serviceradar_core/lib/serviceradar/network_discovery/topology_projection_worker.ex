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

  Uniqueness on the device id is only coalescing. Oban keeps at most one
  pending (available, scheduled or retryable) job per device, and a newer
  result replaces it, so a pending backlog collapses to one run per device. An
  executing job is not pending, so a result that lands during a run still
  enqueues the next one.

  ## Convergence

  Each graph statement commits on its own; no transaction spans a projection.
  When a job reads the device's rows it records a watermark: an md5 of the full
  content of the device's interface rows and of its link rows, computed in
  SQL, so any committed change to a row, an added row or a removed row changes
  it. After a successful projection it reads the watermark again. If a write
  landed in between, or another run for the device read newer rows and
  finished first, the watermark differs and the job enqueues one follow-up
  projection for the device, which reads CNPG again. The graph therefore
  converges to the newest committed rows, however runs for one device overlap.

  Links are read only when observed at or after the stale-link cutoff the
  pruning uses (`TopologyGraph.Utils.stale_cutoff/0`), both for the projection
  and for the link half of the watermark, so retained rows the pruning would
  delete are neither re-projected nor a reason for a follow-up. After a
  successful projection the job schedules `TopologyGlobalPassWorker`, which
  runs the graph-wide pruning and canonical rebuild once per burst.

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
  alias ServiceRadar.NetworkDiscovery.TopologyGlobalPassWorker
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @lane :topology_projection
  @timeout_ms to_timeout(minute: 10)
  @replace [available: [:args], scheduled: [:args], retryable: [:args]]

  @watermark_sql """
  SELECT
    (SELECT md5(coalesce(string_agg(row_to_json(i)::text, ',' ORDER BY i.interface_uid), ''))
     FROM platform.discovered_interfaces i
     WHERE i.device_id = $1),
    (SELECT md5(coalesce(string_agg(row_to_json(l)::text, ',' ORDER BY l.id), ''))
     FROM platform.mapper_topology_links l
     WHERE l.local_device_id = $1 AND l.timestamp >= $2)
  """

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
    cutoff = Utils.stale_cutoff()
    watermark = watermark(device_id, cutoff)

    with :ok <- project(device_id, cutoff, job) do
      if watermark(device_id, cutoff) != watermark, do: enqueue_device(device_id)
      TopologyGlobalPassWorker.schedule()
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

  defp project(device_id, cutoff, job) do
    started = System.monotonic_time(:millisecond)

    result =
      with :ok <- device_id |> load_interfaces() |> TopologyGraph.upsert_interfaces() do
        device_id |> load_links(cutoff) |> TopologyGraph.upsert_links()
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

  defp watermark(device_id, cutoff) do
    %Postgrex.Result{rows: [watermark]} =
      Repo.query!(@watermark_sql, [device_id, DateTime.to_naive(cutoff)])

    watermark
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

  defp load_links(device_id, cutoff) do
    Repo.all(
      from(l in TopologyLink,
        where: l.local_device_id == ^device_id and l.timestamp >= ^cutoff,
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
