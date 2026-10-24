defmodule ServiceRadar.Inventory.Availability.CutoverWorker do
  @moduledoc """
  The work of the stage-c mode switches (`add-merged-device-availability`, design
  Decision 10), enqueued by `ServiceRadar.Inventory.Availability.Mode`. Three phases:

    * `"reconcile"` (after `Mode.enter_cutover/0`): re-resolves every live device from
      its current per-agent ledger rows, evidence and vantage expectations, in uid
      pages of 500 under the device locks, through `Resolution.resolve_locked/2`, the
      path ingestion uses. It never copies the shadow table, so it cannot restore a
      decision that newer evidence superseded. A device whose `is_available` is NULL
      gets false (Decision 6). In `cutover` the resolver writes the device rows and
      suppresses every transition side effect. The rollups are then rebuilt once, and
      `Mode.finish_cutover/0` moves the mode to `authoritative` and enqueues
      `"announce"` in the same transaction.
    * `"announce"`: one summary event with the number of devices whose state now
      differs from their legacy value, per resulting state; then, when transition
      events are on (`ServiceRadar.Inventory.Availability.Transitions`), a
      `device.available` recovery event for each device the legacy value held down and
      the merged state holds available, so a stateful alert the legacy flapping opened
      is closed by the alert engine's own recovery path.
    * `"restore"` (after `Mode.enter_legacy/0` from `cutover` or `authoritative`): sets
      `is_available` from `device_availability_legacy` in uid pages under the device
      locks, which fires the mirror, so `availability_state` returns to the projection of
      the legacy value. The resolver's agent counters and conflict flag are cleared with
      it, because nothing maintains them in `legacy`.

  A fourth phase, `"refresh_rollups"`, is enqueued once by migration
  `20261024120000_add_merged_availability_cutover`: it rebuilds the inventory rollups,
  whose availability counters that migration moved from `is_available` to
  `availability_state`, in any mode.

  The mode-switch phases check the mode first and stop when it no longer applies.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 20

  import Ecto.Query

  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Inventory.Availability.Transitions
  alias ServiceRadar.Inventory.Sync.DeviceWrites
  alias ServiceRadar.Repo

  require Logger

  @switch_phases ["reconcile", "announce", "restore"]
  @phases ["refresh_rollups" | @switch_phases]
  @page_size 500

  @live_page """
  SELECT uid FROM platform.ocsf_devices
  WHERE uid > $1::text AND deleted_at IS NULL
  ORDER BY uid
  LIMIT $2
  """

  @restore_page """
  WITH page AS (
    SELECT d.uid FROM platform.ocsf_devices AS d
    WHERE d.uid > $1::text
    ORDER BY d.uid
    LIMIT $2
    FOR NO KEY UPDATE
  ),
  restored AS (
    UPDATE platform.ocsf_devices AS d
    SET is_available = CASE WHEN l.device_uid IS NULL THEN d.is_available ELSE l.is_available END,
        availability_agents = NULL,
        availability_conflict = false
    FROM page
    LEFT JOIN platform.device_availability_legacy AS l ON l.device_uid = page.uid
    WHERE d.uid = page.uid
      AND (
        d.is_available IS DISTINCT FROM
          (CASE WHEN l.device_uid IS NULL THEN d.is_available ELSE l.is_available END)
        OR d.availability_state IS DISTINCT FROM platform.availability_projection(
          CASE WHEN l.device_uid IS NULL THEN d.is_available ELSE l.is_available END
        )
        OR d.availability_agents IS NOT NULL
        OR d.availability_conflict
      )
    RETURNING d.uid
  )
  SELECT (SELECT count(*) FROM page), (SELECT max(uid) FROM page), (SELECT count(*) FROM restored)
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
    AND d.availability_state = 'available' AND l.is_available IS NOT TRUE
  ORDER BY d.uid
  LIMIT $2
  """

  @doc """
  Enqueues `phase` through the repo, inside the caller's transaction when there is one
  (the mode switch), unless that phase is already waiting.
  """
  @spec enqueue(String.t()) :: :ok
  def enqueue(phase) when phase in @phases do
    if not Repo.exists?(waiting(phase), prefix: "platform") do
      Repo.insert!(new(%{"phase" => phase}), prefix: "platform")
    end

    :ok
  end

  @doc "Deletes every waiting mode-switch job, inside the caller's transaction (a mode switch)."
  @spec cancel_waiting() :: :ok
  def cancel_waiting do
    for phase <- @switch_phases, do: Repo.delete_all(waiting(phase), prefix: "platform")
    :ok
  end

  defp waiting(phase) do
    worker = inspect(__MODULE__)

    Oban.Job
    |> where([j], j.worker == ^worker and j.state in ["available", "scheduled", "retryable"])
    |> where([j], fragment("?->>'phase' = ?", j.args, ^phase))
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"phase" => "reconcile"}}) do
    if Mode.current() == :cutover, do: reconcile(), else: :ok
  end

  def perform(%Oban.Job{args: %{"phase" => "announce"}}) do
    if Mode.current() == :authoritative, do: announce(), else: :ok
  end

  def perform(%Oban.Job{args: %{"phase" => "restore"}}) do
    if Mode.current() == :legacy do
      restored = restore("", 0)
      Logger.info("availability rollback: is_available restored", devices: restored)
    end

    :ok
  end

  def perform(%Oban.Job{args: %{"phase" => "refresh_rollups"}}),
    do: DeviceWrites.refresh_inventory_rollups()

  def perform(%Oban.Job{}), do: :ok

  @doc """
  Re-resolves every live device (in `cutover` only), rebuilds the rollups and moves the
  mode to `authoritative`. Returns the number of devices resolved.
  """
  @spec reconcile() :: :ok | {:error, term()}
  def reconcile do
    {pages, resolved, written} = reconcile_pages("", 0, 0, 0)

    :ok = DeviceWrites.refresh_inventory_rollups()

    Logger.info("availability cutover: reconciliation done",
      pages: pages,
      devices: resolved,
      written: written
    )

    case Mode.finish_cutover() do
      {:ok, _switched} -> :ok
      {:error, {:unsupported_switch, _from, _to}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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

  @doc """
  Publishes the reconciliation summary and the recovery events. Returns `:ok`.
  """
  @spec announce() :: :ok
  def announce do
    %{rows: rows} = Repo.query!(@summary, [], timeout: :infinity)
    counts = Map.new(rows, fn [state, count] -> {state, count} end)
    :ok = Transitions.publish_summary(counts)

    if Transitions.enabled?(), do: recover("", 0), else: 0
    :ok
  end

  defp recover(cursor, published) do
    %{rows: rows} = Repo.query!(@recovered_page, [cursor, @page_size])

    case Enum.map(rows, &hd/1) do
      [] ->
        published

      uids ->
        :ok = Transitions.publish_reconciled_recoveries(uids)
        recover(List.last(uids), published + length(uids))
    end
  end

  defp restore(cursor, restored) do
    {:ok, [count, last, written]} =
      Repo.transaction(fn ->
        %{rows: [row]} = Repo.query!(@restore_page, [cursor, @page_size])
        row
      end)

    if count == 0, do: restored, else: restore(last, restored + written)
  end
end
