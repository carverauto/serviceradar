defmodule ServiceRadar.Inventory.Availability.ReconcileWorker do
  @moduledoc """
  The one-time convergence of a deployment on merged availability
  (`add-merged-device-availability`, `simplify-merged-availability-rollout`), enqueued
  once by migration `20261026220000_converge_merged_availability`. Two phases:

    * `"reconcile"`: re-resolves every live device from its current per-agent ledger
      rows, evidence and vantage expectations, in uid pages of 500 under the device
      locks, through `Resolution`, the path ingestion uses. A device's first merged
      decision (its stored provenance is the `legacy_mirror` a pre-merge release wrote)
      emits no per-device transition. When the migration found the deployment not yet on
      merged availability (`"announce"`), a device that predates availability capture is
      read as the mirror would have shown it until convergence completes. The
      inventory rollups are then rebuilt once, and, for such a deployment, `"announce"`
      is enqueued.
    * `"announce"`: one summary event with the number of live devices whose state now
      differs from their legacy value, per resulting state; then, when transition events
      are on (`ServiceRadar.Inventory.Availability.Transitions`), a `device.available`
      recovery event for each device the legacy value holds down and the merged state
      holds available, so a stateful alert the legacy flapping opened is closed by the
      alert engine's own recovery path.

  Both phases write on change and may be retried. A deployment with no devices finishes
  at once.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 20

  import Ecto.Query

  alias ServiceRadar.Infrastructure.HealthTracker
  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Inventory.Availability.Transitions
  alias ServiceRadar.Inventory.Sync.DeviceWrites
  alias ServiceRadar.Observability.TripwireHealth
  alias ServiceRadar.Repo

  require Logger

  @phases ["reconcile", "announce"]
  @waiting_states ["available", "scheduled", "retryable"]
  @page_size 500

  @live_page """
  SELECT uid FROM platform.ocsf_devices
  WHERE uid > $1::text AND deleted_at IS NULL
  ORDER BY uid
  LIMIT $2
  """

  @summary """
  SELECT d.availability_state, count(*)
  FROM platform.ocsf_devices AS d
  LEFT JOIN platform.device_availability_legacy AS l ON l.device_uid = d.uid
  WHERE d.deleted_at IS NULL
    AND d.availability_state IS DISTINCT FROM
        platform.availability_projection(CASE WHEN l.device_uid IS NULL THEN d.is_available ELSE l.is_available END)
  GROUP BY d.availability_state
  """

  @recovered_page """
  SELECT d.uid FROM platform.ocsf_devices AS d
  JOIN platform.device_availability_legacy AS l ON l.device_uid = d.uid
  WHERE d.uid > $1::text AND d.deleted_at IS NULL
    AND d.availability_state = 'available' AND l.is_available = false
  ORDER BY d.uid
  LIMIT $2
  """

  @doc "Enqueues `phase` with `args` through the repo, unless that phase is already waiting."
  @spec enqueue(String.t(), map()) :: :ok
  def enqueue(phase, args \\ %{}) when phase in @phases do
    worker = inspect(__MODULE__)

    waiting =
      Oban.Job
      |> where([j], j.worker == ^worker and j.state in ^@waiting_states)
      |> where([j], fragment("?->>'phase' = ?", j.args, ^phase))

    if not Repo.exists?(waiting, prefix: "platform") do
      Repo.insert!(new(Map.put(args, "phase", phase)), prefix: "platform")
    end

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"phase" => "reconcile"} = args}) do
    converging? = args["announce"] == true
    {pages, resolved, written} = reconcile_pages("", 0, 0, 0)

    Logger.info("merged availability reconciliation done",
      pages: pages,
      devices: resolved,
      written: written
    )

    with :ok <- DeviceWrites.refresh_inventory_rollups() do
      Repo.query!("""
      UPDATE platform.availability_settings
      SET converged_at = now() AT TIME ZONE 'utc'
      WHERE singleton AND converged_at IS NULL
      """)

      :ok = clear_readiness_warning()
      if converging?, do: enqueue("announce"), else: :ok
    end
  end

  def perform(%Oban.Job{args: %{"phase" => "announce"}}), do: announce()
  def perform(%Oban.Job{}), do: :ok

  defp reconcile_pages(cursor, pages, resolved, written) do
    %{rows: rows} = Repo.query!(@live_page, [cursor, @page_size])

    case Enum.map(rows, &hd/1) do
      [] ->
        {pages, resolved, written}

      uids ->
        {:ok, result} = Repo.transaction(fn -> Resolution.resolve_locked(uids) end)

        reconcile_pages(
          List.last(uids),
          pages + 1,
          resolved + result.resolved,
          written + result.written
        )
    end
  end

  defp clear_readiness_warning do
    case HealthTracker.current_status(:core, "availability_cutover_readiness") do
      {:ok, %{new_state: :unhealthy}} ->
        TripwireHealth.record("availability_cutover_readiness", true, %{"unmet" => []},
          refresh_metadata: true
        )

      other ->
        Logger.warning("availability reconciliation: readiness health check not cleared",
          reason: inspect(other)
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("availability reconciliation: health check read failed",
        reason: inspect(error)
      )

      :ok
  end

  @doc """
  Publishes the reconciliation summary when live devices exist and, when transition
  events are on, the recoveries.
  """
  @spec announce() :: :ok
  def announce do
    %{rows: [[live?]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM platform.ocsf_devices WHERE deleted_at IS NULL)")

    if live? do
      %{rows: rows} = Repo.query!(@summary, [], timeout: :infinity)
      :ok = Transitions.publish_summary(Map.new(rows, &List.to_tuple/1))
    end

    if Transitions.enabled?(), do: recover("")
    :ok
  end

  defp recover(cursor) do
    %{rows: rows} = Repo.query!(@recovered_page, [cursor, @page_size])

    case Enum.map(rows, &hd/1) do
      [] ->
        :ok

      uids ->
        :ok = Transitions.publish_reconciled_recoveries(uids)
        recover(List.last(uids))
    end
  end
end
