defmodule ServiceRadar.Inventory.Availability.ExpiryWorker do
  @moduledoc """
  Re-resolves devices whose evidence or per-agent results aged out
  (`add-merged-device-availability`, design Decision 4). Scheduled every minute; it is
  the only path that changes a decision by the passage of time alone.

  `availability_settings.expiry_watermark` records how far it has got. Each run takes
  the window from the watermark to now in slices of at most 10 minutes. For a slice it
  pages, in uid order and 500 at a time, the devices with

    * an evidence record whose `expires_at` falls in the slice, or
    * a per-agent ledger row whose `checked_at + ttl` falls in it, where the ttl is the
      row's freshness window (`availability_ledger_ttl/1`): one indexed range on
      `checked_at` per distinct window,

  and resolves each page in its own transaction through `Resolution.resolve_locked/2`.
  The resolution takes the device lock first and reads the current committed rows under
  it, so a renewal that committed before the lock is honored; one that commits later
  appended an invalidation, which the resolver worker handles. Only after every page of
  the slice is the watermark advanced, so a failed run is repeated, not skipped.

  The work is bounded by the number of expirations: a renewed row or record moved its
  expiry past the slice and is not selected. A sweep group's interval change or deletion
  moves its rows' windows, possibly behind the watermark, so it is not handled here: a
  trigger on `sweep_groups` appends the group's devices to the invalidation log instead.
  Without a watermark (set by the migration that converged the deployment on merged
  availability) it does nothing.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 55, states: [:available, :scheduled]]

  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Repo

  @slice_seconds 600
  @budget_ms 30_000

  @window """
  SELECT expiry_watermark, clock_timestamp() AT TIME ZONE 'utc'
  FROM platform.availability_settings
  WHERE singleton
  """

  @expired_page """
  WITH windows AS (
    SELECT DISTINCT platform.availability_ledger_ttl(g.id) AS ttl FROM platform.sweep_groups AS g
    UNION
    SELECT interval '2 hours'
  )
  SELECT uid FROM (
    SELECT e.device_uid AS uid
    FROM platform.device_availability_evidence AS e
    WHERE e.expires_at > $1::timestamp AND e.expires_at <= $2::timestamp
    UNION
    SELECT a.device_uid
    FROM windows AS w
    JOIN platform.device_agent_availability AS a
      ON a.checked_at > $1::timestamp - w.ttl
     AND a.checked_at <= $2::timestamp - w.ttl
     AND platform.availability_ledger_ttl(a.sweep_group_id) = w.ttl
  ) AS expired
  WHERE uid > $3::text
  ORDER BY uid
  LIMIT $4
  """

  @advance """
  UPDATE platform.availability_settings
  SET expiry_watermark = $2::timestamp
  WHERE singleton AND expiry_watermark = $1::timestamp
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    run(System.monotonic_time(:millisecond) + @budget_ms, 0)
    :ok
  end

  @doc """
  Processes the window from the watermark to now, slice by slice, until it is caught up
  or the time budget ends. Returns the number of devices re-resolved.
  """
  @spec run(integer(), non_neg_integer()) :: non_neg_integer()
  def run(deadline, resolved) do
    case next_slice() do
      :idle ->
        resolved

      {from, to, caught_up?} ->
        resolved = resolved + resolve_slice(from, to, "", 0)
        Repo.query!(@advance, [from, to])

        :telemetry.execute(
          [:serviceradar, :availability, :expiry],
          %{lag_seconds: if(caught_up?, do: 0, else: NaiveDateTime.diff(to, from))},
          %{}
        )

        if caught_up? or System.monotonic_time(:millisecond) >= deadline,
          do: resolved,
          else: run(deadline, resolved)
    end
  end

  defp next_slice do
    case Repo.query!(@window) do
      %{rows: [[%NaiveDateTime{} = watermark, now]]} ->
        to = NaiveDateTime.add(watermark, @slice_seconds)

        cond do
          NaiveDateTime.compare(now, watermark) != :gt -> :idle
          NaiveDateTime.before?(to, now) -> {watermark, to, false}
          true -> {watermark, now, true}
        end

      _ ->
        :idle
    end
  end

  defp resolve_slice(from, to, cursor, resolved) do
    %{rows: rows} = Repo.query!(@expired_page, [from, to, cursor, Resolution.batch_size()])

    case Enum.map(rows, &hd/1) do
      [] ->
        resolved

      uids ->
        {:ok, result} = Repo.transaction(fn -> Resolution.resolve_locked(uids) end)
        resolve_slice(from, to, List.last(uids), resolved + result.resolved)
    end
  end
end
