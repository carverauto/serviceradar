defmodule ServiceRadar.Inventory.Availability.ShadowEntryWorker do
  @moduledoc """
  The work of entering `shadow` (`add-merged-device-availability`, stage b), enqueued by
  `ServiceRadar.Inventory.Availability.Mode.enter_shadow/1`. Two jobs:

    * `"resolve"`: one full resolution of every live device, paged by uid, 500 per
      transaction, through `Resolution.resolve_locked/2`. The invalidation log is empty
      in `legacy`, so without this a device that sees no new evidence would never get a
      shadow decision. Shadow rows are written on change, so a repeat costs reads only.
      It is scheduled to start `Mode.cache_ms/0` plus 5 seconds after the switch: until
      then a node may still hold a cached `legacy` and skip inline resolution, and a
      pass that read a device before that node's evidence or merge would leave it
      stale. Starting after every cache has expired, the pass covers those writes.
      When it finishes it records its start time as `shadow_resolved_at`, if the mode is
      still `shadow` and it started after `shadow_entered_at`: the automatic cutover
      waits for one such pass (`ServiceRadar.Inventory.Availability.Readiness`).
    * `"seed_legacy"`: copies every device's current `is_available` into
      `device_availability_legacy`, write-on-change, so the divergence report's Armis
      section has a value for devices no legacy writer has touched since stage a. Each
      page locks its device rows `FOR NO KEY UPDATE SKIP LOCKED`, so it never waits on
      a writer; a device a writer held is left to that writer's own trigger, or to a
      later run: the job snoozes while any device still differs.

  Neither phase writes `ocsf_devices`, so no legacy reader, rollup or publisher sees it.
  Both stop when the mode is no longer `shadow`. The seed re-checks the mode before
  every page under the shared mode-switch lock, and does not snooze once that mode
  has left `shadow`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 20

  import Ecto.Query

  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Repo

  require Logger

  @phases ["resolve", "seed_legacy"]
  @waiting_states ["available", "scheduled", "retryable"]
  @seed_page_size 1_000
  @retry_seconds 60
  @cache_margin_ms 5_000

  @live_page """
  SELECT uid FROM platform.ocsf_devices
  WHERE uid > $1::text AND deleted_at IS NULL
  ORDER BY uid
  LIMIT $2
  """

  @seed_page """
  WITH page AS (
    SELECT uid, is_available FROM platform.ocsf_devices
    WHERE uid > $1::text
    ORDER BY uid
    LIMIT $2
    FOR NO KEY UPDATE SKIP LOCKED
  )
  , seeded AS (
    INSERT INTO platform.device_availability_legacy AS legacy (device_uid, is_available, updated_at)
    SELECT uid, is_available, (now() AT TIME ZONE 'utc') FROM page
    ON CONFLICT (device_uid) DO UPDATE
      SET is_available = EXCLUDED.is_available, updated_at = EXCLUDED.updated_at
      WHERE legacy.is_available IS DISTINCT FROM EXCLUDED.is_available
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM page), (SELECT max(uid) FROM page), (SELECT count(*) FROM seeded)
  """

  @now "SELECT now() AT TIME ZONE 'utc'"

  @resolved """
  UPDATE platform.availability_settings
  SET shadow_resolved_at = $1::timestamp
  WHERE singleton AND mode = 'shadow' AND shadow_entered_at <= $1::timestamp
  """

  @seed_pending """
  SELECT EXISTS (
    SELECT 1 FROM platform.ocsf_devices AS d
    LEFT JOIN platform.device_availability_legacy AS legacy ON legacy.device_uid = d.uid
    WHERE legacy.device_uid IS NULL OR legacy.is_available IS DISTINCT FROM d.is_available
  )
  """

  @doc """
  Enqueues both phases through the repo, inside the caller's transaction when there is
  one (the mode switch holds the settings row, so two switches cannot both enqueue). A
  phase that is already waiting to run is not enqueued again; a waiting full pass is
  moved to this entry's cache deadline when that is later, so every entry's pass starts
  after its own deadline. Needs no running Oban
  instance, so the switch works from a release `eval` too.
  """
  @spec enqueue() :: :ok
  def enqueue do
    deadline = DateTime.add(DateTime.utc_now(), Mode.cache_ms() + @cache_margin_ms, :millisecond)

    for phase <- @phases do
      case {phase, Repo.exists?(waiting(phase), prefix: "platform")} do
        {_phase, false} ->
          Repo.insert!(new(%{"phase" => phase}, job_opts(phase, deadline)), prefix: "platform")

        {"resolve", true} ->
          "resolve"
          |> waiting()
          |> update([j],
            set: [
              state: "scheduled",
              scheduled_at:
                fragment("GREATEST(?, ?)", j.scheduled_at, type(^deadline, :utc_datetime_usec))
            ]
          )
          |> Repo.update_all([], prefix: "platform")

        {_phase, true} ->
          :ok
      end
    end

    :ok
  end

  @doc """
  Deletes every waiting entry job, inside the caller's transaction (the rollback to
  `legacy`), so a later entry schedules its own full pass.
  """
  @spec cancel_waiting() :: :ok
  def cancel_waiting do
    for phase <- @phases, do: Repo.delete_all(waiting(phase), prefix: "platform")
    :ok
  end

  @doc "Whether a job of `phase` is waiting or executing."
  @spec outstanding?(String.t()) :: boolean()
  def outstanding?(phase) when phase in @phases,
    do: Repo.exists?(phase_jobs(phase, ["executing" | @waiting_states]), prefix: "platform")

  defp waiting(phase), do: phase_jobs(phase, @waiting_states)

  defp phase_jobs(phase, states) do
    worker = inspect(__MODULE__)

    Oban.Job
    |> where([j], j.worker == ^worker and j.state in ^states)
    |> where([j], fragment("?->>'phase' = ?", j.args, ^phase))
  end

  defp job_opts("resolve", deadline), do: [scheduled_at: deadline]
  defp job_opts(_phase, _deadline), do: []

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"phase" => "resolve"}}) do
    if Mode.current() == :shadow do
      %{rows: [[started_at]]} = Repo.query!(@now)
      {pages, resolved} = resolve_all("", 0, 0)
      Repo.query!(@resolved, [started_at])

      Logger.info("availability shadow entry: full resolution done",
        pages: pages,
        devices: resolved
      )
    end

    :ok
  end

  def perform(%Oban.Job{args: %{"phase" => "seed_legacy"}}) do
    if Mode.current() == :shadow do
      case seed_all("", 0) do
        {:left_shadow, seeded} ->
          Logger.info("availability shadow entry: compatibility table seeded", rows: seeded)
          :ok

        seeded ->
          Logger.info("availability shadow entry: compatibility table seeded", rows: seeded)
          if pending?(), do: {:snooze, @retry_seconds}, else: :ok
      end
    else
      :ok
    end
  end

  def perform(%Oban.Job{}), do: :ok

  defp resolve_all(cursor, pages, resolved) do
    %{rows: rows} = Repo.query!(@live_page, [cursor, Resolution.batch_size()])

    case Enum.map(rows, &hd/1) do
      [] ->
        {pages, resolved}

      uids ->
        {:ok, result} = Repo.transaction(fn -> Resolution.resolve_locked(uids) end)
        resolve_all(List.last(uids), pages + 1, resolved + result.resolved)
    end
  end

  defp seed_all(cursor, seeded) do
    case Repo.transaction(fn -> seed_page(cursor) end) do
      {:ok, :left_shadow} ->
        {:left_shadow, seeded}

      {:ok, [count, _last, _written]} when count == 0 ->
        seeded

      {:ok, [_count, last, written]} ->
        seed_all(last, seeded + written)
    end
  end

  defp seed_page(cursor) do
    if Mode.admit() == :shadow do
      %{rows: [row]} = Repo.query!(@seed_page, [cursor, @seed_page_size])
      row
    else
      :left_shadow
    end
  end

  defp pending? do
    %{rows: [[pending?]]} = Repo.query!(@seed_pending)
    pending?
  end
end
