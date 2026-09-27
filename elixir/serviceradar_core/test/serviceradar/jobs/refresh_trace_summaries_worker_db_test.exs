defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorkerDbTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Jobs.RefreshTraceSummariesWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  @moduletag :integration

  @worker inspect(RefreshTraceSummariesWorker)

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    # Drain only this test's jobs: the sandbox rolls these deletes back.
    Repo.delete_all(from(job in Oban.Job, where: job.queue == "maintenance"))
    set_watermark!(DateTime.add(DateTime.utc_now(), -300, :second))
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
    early_trace = insert_span!(DateTime.add(now, -10, :second))

    # A batch the run cannot cover: stamped after the run's upper bound, the way a span committed
    # while the refresh is executing is. The margin keeps a slow runner from reaching it.
    late_trace = insert_span!(DateTime.add(now, 1, :hour))

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

  defp request_refresh do
    %{} |> RefreshTraceSummariesWorker.new() |> ObanSupport.safe_insert()
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
