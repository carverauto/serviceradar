defmodule ServiceRadar.Inventory.Availability.CutoverWorker do
  @moduledoc """
  The work of the stage-c mode switches (`add-merged-device-availability`, design
  Decision 10), enqueued by `ServiceRadar.Inventory.Availability.Mode`. Three phases:

    * `"reconcile"` (after `Mode.enter_cutover/1`): re-resolves every live device from
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
    * `"restore"` (after `Mode.enter_legacy/1` from `cutover` or `authoritative`): sets
      `is_available` from `device_availability_legacy` in uid pages under the device
      locks, which fires the mirror, so `availability_state` returns to the projection of
      the legacy value. The resolver's agent counters and conflict flag are cleared with
      it, because nothing maintains them in `legacy`.

  A fourth phase, `"refresh_rollups"`, is enqueued once by migration
  `20261024120000_add_merged_availability_cutover`: it rebuilds the inventory rollups,
  whose availability counters that migration moved from `is_available` to
  `availability_state`, in any mode.

  The mode-switch phases check the mode first and stop when it no longer applies.
  Reconciliation checks again, under the shared mode-switch lock, before every page and
  before rebuilding rollups or calling `Mode.finish_cutover/0`: once the mode is no
  longer `cutover` it resolves nothing further. Announce checks again before the summary
  and before each recovery page and stops unless the mode is `authoritative`. Restore
  checks again before each page and stops unless the mode is `legacy`. An executing
  reconcile counts as queued; the other phases do not. `cancel_waiting/0` still removes
  only jobs that have not started.
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
  @queued_states ["available", "scheduled", "retryable"]
  @queued_or_running ["executing" | @queued_states]
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

  # Every device that has a compatibility row, deleted or not. A device with no row is
  # not a mismatch: the first shadow entry has to seed it. Same rows the restore page writes.
  @restore_incomplete """
  SELECT EXISTS (
    SELECT 1
    FROM platform.device_availability_legacy AS l
    JOIN platform.ocsf_devices AS d ON d.uid = l.device_uid
    WHERE d.is_available IS DISTINCT FROM l.is_available
  )
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

  @doc """
  Enqueues `phase` through the repo, inside the caller's transaction when there is one
  (the mode switch), unless that phase is already waiting. An executing reconcile also
  counts as queued; an executing announce, restore or rollup refresh does not.
  """
  @spec enqueue(String.t()) :: :ok
  def enqueue(phase) when phase in @phases do
    if not Repo.exists?(phase_jobs(phase, queued_states(phase)), prefix: "platform") do
      Repo.insert!(new(%{"phase" => phase}), prefix: "platform")
    end

    :ok
  end

  @doc "Whether a job of `phase` is waiting or executing."
  @spec outstanding?(String.t()) :: boolean()
  def outstanding?(phase) when phase in @phases,
    do: Repo.exists?(phase_jobs(phase, @queued_or_running), prefix: "platform")

  @doc """
  Whether a rollback has not put `is_available` back: some compatibility row still
  differs from its device. A discarded restore leaves no job, so this is what keeps
  the next shadow entry from copying the unrestored column over the snapshot.
  """
  @spec restore_incomplete?() :: boolean()
  def restore_incomplete? do
    %{rows: [[incomplete?]]} = Repo.query!(@restore_incomplete)
    incomplete?
  end

  defp queued_states("reconcile"), do: @queued_or_running
  defp queued_states(_phase), do: @queued_states

  @doc "Deletes every waiting mode-switch job, inside the caller's transaction (a mode switch)."
  @spec cancel_waiting() :: :ok
  def cancel_waiting do
    for phase <- @switch_phases, do: Repo.delete_all(waiting(phase), prefix: "platform")
    :ok
  end

  defp waiting(phase), do: phase_jobs(phase, @queued_states)

  defp phase_jobs(phase, states) do
    worker = inspect(__MODULE__)

    Oban.Job
    |> where([j], j.worker == ^worker and j.state in ^states)
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
  Re-resolves every live device while the mode stays `cutover`, then rebuilds the
  rollups and moves the mode to `authoritative`. A mode change ends the run first.
  """
  @spec reconcile() :: :ok | {:error, term()}
  def reconcile do
    case reconcile_pages("", 0, 0, 0) do
      :left_cutover ->
        :ok

      {pages, resolved, written} ->
        case refresh_while_cutover() do
          :left_cutover ->
            :ok

          :ok ->
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

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp reconcile_pages(cursor, pages, resolved, written) do
    %{rows: rows} = Repo.query!(@live_page, [cursor, @page_size])

    case Enum.map(rows, &hd/1) do
      [] ->
        {pages, resolved, written}

      uids ->
        case Repo.transaction(fn -> resolve_cutover_page(uids) end) do
          {:ok, :left_cutover} ->
            :left_cutover

          {:ok, result} ->
            reconcile_pages(
              List.last(uids),
              pages + 1,
              resolved + result.resolved,
              written + result.written
            )
        end
    end
  end

  defp resolve_cutover_page(uids) do
    if Mode.admit() == :cutover do
      Resolution.resolve_locked(uids)
    else
      :left_cutover
    end
  end

  defp refresh_while_cutover do
    case Repo.transaction(fn -> refresh_cutover_rollups() end, timeout: :infinity) do
      {:ok, :left_cutover} -> :left_cutover
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_cutover_rollups do
    if Mode.admit() == :cutover do
      case DeviceWrites.refresh_inventory_rollups() do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      :left_cutover
    end
  end

  @doc """
  Publishes the reconciliation summary and the recovery events while the mode is
  `authoritative`, and stops when it is not. Returns `:ok`.
  """
  @spec announce() :: :ok
  def announce do
    if Mode.current() == :authoritative do
      %{rows: rows} = Repo.query!(@summary, [], timeout: :infinity)
      counts = Map.new(rows, fn [state, count] -> {state, count} end)
      :ok = Transitions.publish_summary(counts)

      if Transitions.enabled?(), do: recover("", 0)
    end

    :ok
  end

  defp recover(cursor, published) do
    if Mode.current() == :authoritative do
      %{rows: rows} = Repo.query!(@recovered_page, [cursor, @page_size])

      case Enum.map(rows, &hd/1) do
        [] ->
          published

        uids ->
          :ok = Transitions.publish_reconciled_recoveries(uids)
          recover(List.last(uids), published + length(uids))
      end
    else
      published
    end
  end

  defp restore(cursor, restored) do
    if Mode.current() == :legacy do
      {:ok, [count, last, written]} =
        Repo.transaction(fn ->
          %{rows: [row]} = Repo.query!(@restore_page, [cursor, @page_size])
          row
        end)

      if count == 0, do: restored, else: restore(last, restored + written)
    else
      restored
    end
  end
end
