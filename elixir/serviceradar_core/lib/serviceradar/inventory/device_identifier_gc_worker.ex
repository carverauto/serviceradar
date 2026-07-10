defmodule ServiceRadar.Inventory.DeviceIdentifierGcWorker do
  @moduledoc """
  Daily Oban worker that garbage-collects unseen device identifiers.

  Identifier rows accumulate forever today (`device_identifiers` has never
  seen a delete). This worker deletes rows whose `last_seen` is older than a
  configurable TTL (default 90 days) in bounded `LIMIT` batches.

  Safety rails:

    * `agent_id` identifiers belonging to an agent that still exists in
      `ocsf_agents` are never deleted, regardless of age. Their placement is
      maintained by `ServiceRadar.Inventory.AgentLinkRepairWorker`.
    * Deletes are batched (`batch_size` rows per delete, at most
      `max_batches` batches per run) so a backlogged table cannot wedge the
      maintenance queue.

  Each run logs a summary and emits
  `[:serviceradar, :device_identifier_gc, :run]` with the total deleted
  count plus a per-identifier-type breakdown.

  Configuration (all optional):

      config :serviceradar_core, ServiceRadar.Inventory.DeviceIdentifierGcWorker,
        enabled: true,
        ttl_days: 90,
        batch_size: 5_000,
        max_batches: 200,
        reschedule_seconds: 86_400
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_ttl_days 90
  @default_batch_size 5_000
  @default_max_batches 200
  @default_reschedule_seconds 86_400

  @schema_prefix "platform"

  @spec ensure_scheduled() :: {:ok, Oban.Job.t() | :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if job_already_scheduled?() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    if Keyword.get(config, :enabled, true) do
      run_gc(config)
    else
      Logger.info("DeviceIdentifierGcWorker: disabled, skipping run")
    end

    reschedule(config)
    :ok
  end

  @doc """
  Run a single GC pass and return run statistics.

  Exposed for tests and manual invocation; `perform/1` wraps this with
  rescheduling.
  """
  @spec run_gc(keyword()) :: map()
  def run_gc(config \\ []) do
    ttl_days = positive_int(Keyword.get(config, :ttl_days), @default_ttl_days)
    batch_size = positive_int(Keyword.get(config, :batch_size), @default_batch_size)
    max_batches = positive_int(Keyword.get(config, :max_batches), @default_max_batches)

    cutoff = DateTime.add(DateTime.utc_now(), -ttl_days * 86_400, :second)
    protected_agent_uids = linked_agent_uids()

    stats =
      delete_batches(cutoff, protected_agent_uids, batch_size, max_batches, %{
        deleted: 0,
        batches: 0,
        counts_by_type: %{},
        exhausted: false
      })

    Logger.info(
      "DeviceIdentifierGcWorker: run completed",
      deleted: stats.deleted,
      batches: stats.batches,
      ttl_days: ttl_days,
      counts_by_type: inspect(stats.counts_by_type),
      budget_exhausted: stats.exhausted
    )

    :telemetry.execute(
      [:serviceradar, :device_identifier_gc, :run],
      %{deleted: stats.deleted, batches: stats.batches},
      %{
        counts_by_type: stats.counts_by_type,
        ttl_days: ttl_days,
        cutoff: cutoff,
        budget_exhausted: stats.exhausted
      }
    )

    stats
  end

  defp delete_batches(_cutoff, _protected, _batch_size, 0, stats) do
    %{stats | exhausted: true}
  end

  defp delete_batches(cutoff, protected, batch_size, batches_left, stats) do
    victims = victim_batch(cutoff, protected, batch_size)

    case victims do
      [] ->
        stats

      victims ->
        ids = Enum.map(victims, fn {id, _type} -> id end)

        {deleted_count, _} =
          Repo.delete_all(from(di in "device_identifiers", where: di.id in ^ids),
            prefix: @schema_prefix
          )

        counts_by_type =
          Enum.reduce(victims, stats.counts_by_type, fn {_id, type}, acc ->
            Map.update(acc, type, 1, &(&1 + 1))
          end)

        stats = %{
          stats
          | deleted: stats.deleted + deleted_count,
            batches: stats.batches + 1,
            counts_by_type: counts_by_type
        }

        if length(victims) < batch_size do
          stats
        else
          delete_batches(cutoff, protected, batch_size, batches_left - 1, stats)
        end
    end
  end

  defp victim_batch(cutoff, protected_agent_uids, batch_size) do
    query =
      from(di in "device_identifiers",
        where: di.last_seen < ^cutoff,
        where:
          di.identifier_type != "agent_id" or
            di.identifier_value not in ^protected_agent_uids,
        # ADDITIVE guard: never GC a `mac` row whose parent device was
        # tombstoned by the armis_source_device_id_ghost_cleanup. Those ~389k
        # rows are sole-copy hardware MAC bindings whose disposition is not yet
        # complete; the armis-overmerge cleanup left them inside the 90-day
        # TTL, so without this clause the daily GC would silently delete every
        # one once they age out. This only NARROWS the victim set — it can
        # never delete more than before. Remove once disposition completes.
        where:
          di.identifier_type != "mac" or
            fragment(
              "NOT EXISTS (SELECT 1 FROM platform.ocsf_devices d WHERE d.uid = ? AND d.deleted_reason = 'armis_source_device_id_ghost_cleanup')",
              di.device_id
            ),
        order_by: [asc: di.id],
        limit: ^batch_size,
        select: {di.id, di.identifier_type}
      )

    Repo.all(query, prefix: @schema_prefix)
  end

  # Every agent uid currently present in ocsf_agents is protected: its
  # agent_id identifier is the strong anchor used to resolve the agent's
  # device and must never be GC'd while the agent row exists. The table is
  # small (one row per agent), so loading the uid list is bounded.
  defp linked_agent_uids do
    Repo.all(from(a in "ocsf_agents", select: a.uid), prefix: @schema_prefix)
  end

  defp reschedule(config) do
    reschedule_seconds =
      positive_int(Keyword.get(config, :reschedule_seconds), @default_reschedule_seconds)

    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 3_600)))
    :ok
  end

  defp job_already_scheduled? do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end
