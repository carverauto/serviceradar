defmodule ServiceRadar.Inventory.Availability.CaptureBackfillWorker do
  @moduledoc """
  One-off backfill for stage a of `add-merged-device-availability`, enqueued once by
  migration `20261019180000_add_merged_availability_capture`.

  1. Projects `ocsf_devices.availability_state` from `is_available` for every existing
     device, the value the mirror trigger keeps for every later write.
  2. Seeds `device_agent_availability.consecutive_down` for each unreachable ledger row
     from its device's `metadata.sweep_consecutive_failures`, at least 1 and capped at
     the `active_probe` threshold of 2. Apart from the legacy hysteresis computation,
     this is the only reader of that key.

  Vantage expectations and `operator_policy` evidence need no backfill here: the next
  full pass of each enabled composite check writes both.

  Both steps page in key order and lock with `SKIP LOCKED`, so the backfill never waits
  on a writer and cannot deadlock with one. A row a writer held is left for a later run:
  if any mismatch remains, the job snoozes and starts again. Re-running is a no-op.
  Neither step changes `is_available`, `checked_at` or ledger `updated_at`, so legacy
  readers and composite-check dirty tracking see nothing.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 20

  alias ServiceRadar.Repo

  require Logger

  @page_size 1_000
  @max_pages_per_run 500
  @retry_seconds 60

  @project_page """
  WITH page AS (
    SELECT uid FROM platform.ocsf_devices
    WHERE uid > $1::text
      AND availability_state IS DISTINCT FROM platform.availability_projection(is_available)
    ORDER BY uid
    LIMIT $2
    FOR NO KEY UPDATE SKIP LOCKED
  )
  , updated AS (
    UPDATE platform.ocsf_devices AS d
    SET availability_state = platform.availability_projection(d.is_available),
        availability_changed_at = (now() AT TIME ZONE 'utc'),
        availability_decided_by = jsonb_build_object('rule', 'legacy_mirror')
    FROM page
    WHERE d.uid = page.uid
    RETURNING d.uid
  )
  SELECT count(*), max(uid) FROM updated
  """

  @projection_pending """
  SELECT EXISTS (
    SELECT 1 FROM platform.ocsf_devices
    WHERE availability_state IS DISTINCT FROM platform.availability_projection(is_available)
  )
  """

  @counter_page """
  WITH page AS (
    SELECT id FROM platform.device_agent_availability
    WHERE id > $1::text::uuid AND is_available = false AND consecutive_down = 0
    ORDER BY id
    LIMIT $2
    FOR NO KEY UPDATE SKIP LOCKED
  )
  , updated AS (
    UPDATE platform.device_agent_availability AS a
    SET consecutive_down = LEAST(GREATEST(COALESCE(
          CASE WHEN d.metadata ->> 'sweep_consecutive_failures' ~ '^[0-9]{1,9}$'
               THEN (d.metadata ->> 'sweep_consecutive_failures')::integer
          END, 1), 1), 2)
    FROM page, platform.ocsf_devices AS d
    WHERE a.id = page.id AND d.uid = a.device_uid
    RETURNING a.id
  )
  SELECT count(*), ((array_agg(id ORDER BY id DESC))[1])::text FROM updated
  """

  @counter_pending """
  SELECT EXISTS (
    SELECT 1 FROM platform.device_agent_availability
    WHERE is_available = false AND consecutive_down = 0
  )
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if mirror_mode?() do
      projected = run_pages(@project_page, "")
      counted = run_pages(@counter_page, "00000000-0000-0000-0000-000000000000")

      Logger.info("availability capture backfill pass",
        devices_projected: projected,
        ledger_rows_counted: counted
      )

      if pending?(), do: {:snooze, @retry_seconds}, else: :ok
    else
      # The mirror only applies in legacy and shadow; another mode owns the state.
      :ok
    end
  end

  defp mirror_mode? do
    %{rows: [[mode]]} = Repo.query!("SELECT platform.availability_mode()")
    mode in ["legacy", "shadow"]
  end

  defp run_pages(sql, cursor), do: run_pages(sql, cursor, 0, 0)

  defp run_pages(_sql, _cursor, @max_pages_per_run, total), do: total

  defp run_pages(sql, cursor, pages, total) do
    # The cursor is the page's largest key in the database's own ordering, so paging
    # never depends on how Elixir would compare the keys.
    {:ok, [count, last]} =
      Repo.transaction(fn ->
        # The projection changes availability_state, which the inventory rollups count
        # (migration 20261024120000), so their triggers run.
        %{rows: [row]} = Repo.query!(sql, [cursor, @page_size])
        row
      end)

    case count do
      0 -> total
      count -> run_pages(sql, last, pages + 1, total + count)
    end
  end

  @doc """
  Whether the backfill has work left: a device whose `availability_state` is not the
  projection of its `is_available`, or an unreachable ledger row with no counter. The
  automatic cutover waits until neither remains
  (`ServiceRadar.Inventory.Availability.Readiness`).
  """
  @spec pending?() :: boolean()
  def pending?, do: pending?(@projection_pending) or pending?(@counter_pending)

  defp pending?(sql) do
    %{rows: [[pending?]]} = Repo.query!(sql)
    pending?
  end
end
