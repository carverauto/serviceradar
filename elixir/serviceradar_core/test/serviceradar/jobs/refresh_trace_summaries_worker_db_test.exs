defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorkerDbTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Jobs.ReapStalePeriodicJobsWorker
  alias ServiceRadar.Jobs.RefreshTraceSummariesWorker
  alias ServiceRadar.Repo

  @moduletag :integration

  @worker inspect(RefreshTraceSummariesWorker)

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    # Drain only this test's jobs: the sandbox rolls these deletes back.
    Repo.delete_all(from(job in Oban.Job, where: job.queue == "maintenance"))
    set_watermark!(DateTime.shift(DateTime.utc_now(), minute: -5))
    # No run has committed recently, which is what an orphan looks like.
    age_watermark_write!(3600)
    :ok
  end

  test "ingest enqueues during an executing refresh coalesce into the running job" do
    executing =
      %{}
      |> RefreshTraceSummariesWorker.new()
      |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.utc_now(), attempt: 1)
      |> Repo.insert!()

    for _burst <- 1..3 do
      assert {:ok, %Oban.Job{conflict?: true, id: id}} = request_refresh()
      assert id == executing.id
    end

    assert [%Oban.Job{id: id, state: "executing"}] = incomplete_jobs()
    assert id == executing.id
  end

  test "a run that ends with spans past its watermark schedules one follow-up that summarizes them" do
    now = DateTime.utc_now()
    early_trace = insert_span!(DateTime.shift(now, second: -10))

    # A batch the run cannot cover: stamped after the run's upper bound, the way a span committed
    # while the refresh is executing is. The margin keeps a slow runner from reaching it.
    late_trace = insert_span!(DateTime.shift(now, hour: 1))

    assert {:ok, %Oban.Job{id: job_id, conflict?: false}} = request_refresh()

    assert %{snoozed: 1, success: 0} = Oban.drain_queue(queue: :maintenance)

    assert summarized?(early_trace)
    refute summarized?(late_trace)

    # The follow-up is the same row, rescheduled: exactly one pending refresh, and a burst of
    # ingest enqueues coalesces into it instead of piling up.
    assert [%Oban.Job{id: ^job_id, state: "scheduled"}] = incomplete_jobs()

    for _burst <- 1..3 do
      assert {:ok, %Oban.Job{conflict?: true, id: ^job_id}} = request_refresh()
    end

    # Time passes: the batch's ingest stamp falls inside the follow-up's window.
    restamp_span!(late_trace, DateTime.utc_now())

    assert %{success: 1, snoozed: 0} =
             Oban.drain_queue(queue: :maintenance, with_scheduled: true)

    assert summarized?(late_trace)

    # Nothing was ingested past the follow-up's watermark, so it does not schedule another.
    assert incomplete_jobs() == []
  end

  describe "orphaned executing refresh" do
    # A node stopped mid-run: Oban's row is still `executing`, but Postgres rolled the run's
    # transaction back and released its lock. Every enqueue coalesces into the dead row, so
    # without a rescue nothing refreshes until the 240-minute age-based rescuers fire.
    test "is rescued when the refresh lock is free, and the refresh then runs" do
      trace = insert_span!(DateTime.shift(DateTime.utc_now(), second: -10))
      orphan = insert_executing!(attempted_seconds_ago: 300, attempt: 1)

      assert {:ok, [%{id: id}]} = RefreshTraceSummariesWorker.rescue_orphaned()
      assert id == orphan.id

      rescued = Repo.reload!(orphan)
      assert rescued.state == "available"
      # The killed attempt is not charged: max_attempts rises like a snooze does.
      assert rescued.max_attempts == orphan.max_attempts + 1
      assert [%{"attempt" => 1, "error" => "orphaned: " <> _}] = rescued.errors

      # Still the one incomplete row, so enqueues keep coalescing into it.
      assert [%Oban.Job{id: ^id}] = incomplete_jobs()
      assert {:ok, %Oban.Job{conflict?: true, id: ^id}} = request_refresh()

      assert %{success: 1} = Oban.drain_queue(queue: :maintenance)
      assert summarized?(trace)
      assert incomplete_jobs() == []
    end

    test "is not rescued while another connection holds the refresh lock" do
      orphan = insert_executing!(attempted_seconds_ago: 300, attempt: 1)
      release = hold_refresh_lock_elsewhere!()

      assert {:ok, []} = RefreshTraceSummariesWorker.rescue_orphaned()
      assert {:ok, %{rescued_jobs: []}} = ReapStalePeriodicJobsWorker.reap_stale_jobs()
      assert %Oban.Job{state: "executing"} = Repo.reload!(orphan)

      release.()
    end

    test "is not rescued within the grace after it was attempted" do
      orphan = insert_executing!(attempted_seconds_ago: 5, attempt: 1)

      assert {:ok, []} = RefreshTraceSummariesWorker.rescue_orphaned()
      assert %Oban.Job{state: "executing"} = Repo.reload!(orphan)
    end

    # A live run releases the lock at commit and then runs its trailing-refresh probe before
    # Oban records the outcome; the watermark it just wrote is what marks that window.
    test "is not rescued while the watermark was written within the grace" do
      orphan = insert_executing!(attempted_seconds_ago: 300, attempt: 1)
      age_watermark_write!(0)

      assert {:ok, []} = RefreshTraceSummariesWorker.rescue_orphaned()
      assert %Oban.Job{state: "executing"} = Repo.reload!(orphan)
    end

    test "on its last attempt is rescued without stranding it unfetchable" do
      orphan = insert_executing!(attempted_seconds_ago: 300, attempt: 3)

      assert {:ok, [_rescued]} = RefreshTraceSummariesWorker.rescue_orphaned()

      rescued = Repo.reload!(orphan)
      assert rescued.state == "available"
      assert rescued.attempt < rescued.max_attempts
    end

    test "is rescued from the ingest enqueue path when the insert collides with it" do
      put_worker_env(:orphan_probe_interval_ms, 1)
      orphan = insert_executing!(attempted_seconds_ago: 300, attempt: 1)
      Process.sleep(2)

      assert {:ok, %Oban.Job{conflict?: true, id: id}} = request_refresh()
      assert id == orphan.id
      assert %Oban.Job{state: "available"} = Repo.reload!(orphan)
    end

    test "is probed from the ingest path at most once per interval on a node" do
      put_worker_env(:orphan_probe_interval_ms, 1)
      first = insert_executing!(attempted_seconds_ago: 300, attempt: 1)
      Process.sleep(2)
      assert {:ok, %Oban.Job{id: first_id}} = request_refresh()
      assert first_id == first.id
      assert %Oban.Job{state: "available"} = Repo.reload!(first)

      # The probe above started the interval; a second orphan inside it is left for later.
      put_worker_env(:orphan_probe_interval_ms, to_timeout(hour: 1))
      Repo.delete!(Repo.reload!(first))
      second = insert_executing!(attempted_seconds_ago: 300, attempt: 1)

      assert {:ok, %Oban.Job{conflict?: true, id: second_id}} = request_refresh()
      assert second_id == second.id
      assert %Oban.Job{state: "executing"} = Repo.reload!(second)
    end

    test "is rescued by the periodic reaper long before its age threshold" do
      orphan = insert_executing!(attempted_seconds_ago: 300, attempt: 1)
      assert ReapStalePeriodicJobsWorker.stale_threshold_minutes() * 60 > 300

      # The sweep derives worker names from every AshOban resource inside its
      # transaction; a cold test VM loads those modules lazily, which can outlast the
      # connection's checkout timeout. A release preloads them.
      _names = ReapStalePeriodicJobsWorker.periodic_worker_names()

      assert {:ok, %{rescued_jobs: rescued, discarded_jobs: []}} =
               ReapStalePeriodicJobsWorker.reap_stale_jobs()

      assert Enum.map(rescued, & &1.id) == [orphan.id]
      assert %Oban.Job{state: "available"} = Repo.reload!(orphan)
    end
  end

  defp request_refresh, do: RefreshTraceSummariesWorker.enqueue()

  defp insert_executing!(opts) do
    attempted_at =
      DateTime.shift(DateTime.utc_now(), second: -Keyword.fetch!(opts, :attempted_seconds_ago))

    %{}
    |> RefreshTraceSummariesWorker.new()
    |> Ecto.Changeset.change(
      state: "executing",
      attempted_at: attempted_at,
      attempted_by: ["core@node01.example.com", Ecto.UUID.generate()],
      attempt: Keyword.fetch!(opts, :attempt)
    )
    |> Repo.insert!()
  end

  # Holds the refresh lock the way a live run's transaction does, on a connection outside
  # this test's sandbox so it is a different backend from the one the probe uses. Returns the
  # function that releases it.
  defp hold_refresh_lock_elsewhere! do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :name])
    {:ok, conn} = Postgrex.start_link(Keyword.put(config, :pool_size, 1))
    parent = self()

    holder =
      spawn(fn ->
        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            RefreshTraceSummariesWorker.watermark_key()
          ])

          send(parent, {:refresh_lock_held, self()})

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end)

        send(parent, :refresh_lock_released)
      end)

    assert_receive {:refresh_lock_held, ^holder}, 10_000

    release = fn ->
      send(holder, :release)
      assert_receive :refresh_lock_released, 10_000
      GenServer.stop(conn)
    end

    on_exit(fn -> if Process.alive?(holder), do: send(holder, :release) end)
    release
  end

  defp put_worker_env(key, value) do
    previous = Application.get_env(:serviceradar_core, RefreshTraceSummariesWorker)
    config = Keyword.put(previous || [], key, value)
    Application.put_env(:serviceradar_core, RefreshTraceSummariesWorker, config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_core, RefreshTraceSummariesWorker, previous),
        else: Application.delete_env(:serviceradar_core, RefreshTraceSummariesWorker)
    end)
  end

  defp age_watermark_write!(seconds) do
    SQL.query!(
      Repo,
      "UPDATE observability_watermarks SET updated_at = NOW() - ($2::int * INTERVAL '1 second') WHERE key = $1",
      [RefreshTraceSummariesWorker.watermark_key(), seconds]
    )
  end

  defp incomplete_jobs do
    Repo.all(
      from(job in Oban.Job,
        where:
          job.worker == ^@worker and
            job.state in ["available", "scheduled", "executing", "retryable", "suspended"]
      )
    )
  end

  defp set_watermark!(watermark) do
    SQL.query!(
      Repo,
      """
      INSERT INTO observability_watermarks (key, watermark, updated_at)
      VALUES ($1, $2, NOW())
      ON CONFLICT (key) DO UPDATE SET watermark = EXCLUDED.watermark, updated_at = NOW()
      """,
      [RefreshTraceSummariesWorker.watermark_key(), watermark]
    )
  end

  defp insert_span!(created_at) do
    trace_id = random_hex(16)
    start_ns = System.os_time(:nanosecond)

    SQL.query!(
      Repo,
      """
      INSERT INTO otel_traces (
        timestamp, trace_id, span_id, parent_span_id, name, kind, service_name,
        start_time_unix_nano, end_time_unix_nano, status_code, created_at
      )
      VALUES (NOW(), $1, $2, NULL, 'GET /synthetic', 2, 'synthetic-service', $3, $4, 1, $5)
      """,
      [trace_id, random_hex(8), start_ns, start_ns + 5_000_000, created_at]
    )

    trace_id
  end

  defp summarized?(trace_id) do
    %{rows: [[count]]} =
      SQL.query!(Repo, "SELECT count(*) FROM otel_trace_summaries WHERE trace_id = $1", [
        trace_id
      ])

    count == 1
  end

  defp restamp_span!(trace_id, created_at) do
    SQL.query!(Repo, "UPDATE otel_traces SET created_at = $2 WHERE trace_id = $1", [
      trace_id,
      created_at
    ])
  end

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
