defmodule ServiceRadar.Jobs.ScheduleHealthWorkerTest do
  @moduledoc """
  Integration coverage for schedule-health alerting (DIRE task 6.4) and the
  nil-actor scheduler-read regression that killed the reconcile cron on
  2026-02-06.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Jobs.JobSchedule
  alias ServiceRadar.Jobs.ScheduleHealthWorker
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:schedule_health_worker_test)
    {:ok, actor: actor}
  end

  test "AshOban scheduler read action returns enabled schedules with a nil actor",
       %{actor: actor} do
    # Regression: PR #2713 restricted JobSchedule reads to viewer+, which
    # silently filtered the AshOban scheduler's nil-actor read to zero rows
    # and stopped identity reconciliation from being enqueued. The
    # :identity_reconciliation read action must work without an actor.
    _schedule = ensure_identity_schedule(actor)

    assert {:ok, results} =
             JobSchedule
             |> Ash.Query.for_read(:identity_reconciliation)
             |> Ash.read(actor: nil)
             |> Page.unwrap()

    assert Enum.any?(results, &(&1.job_key == JobSchedule.identity_reconciliation_job_key()))
  end

  test "alerts on enabled schedules whose last enqueue is older than 2x interval",
       %{actor: actor} do
    suffix = System.unique_integer([:positive, :monotonic])
    job_key = "health-test-#{suffix}"

    {:ok, schedule} =
      JobSchedule
      |> Ash.Changeset.for_create(:create, %{
        job_key: job_key,
        cron: "*/5 * * * *",
        timezone: "Etc/UTC",
        args: %{},
        enabled: true
      })
      |> Ash.create(actor: actor)

    stale_time = DateTime.add(DateTime.utc_now(), -4 * 3_600, :second)

    {:ok, _schedule} =
      schedule
      |> Ash.Changeset.for_update(:update_last_enqueued, %{last_enqueued_at: stale_time})
      |> Ash.update(actor: actor)

    handler_id = "schedule-health-test-#{suffix}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :job_schedule, :health, :stale],
        fn _event, measurements, metadata, _config ->
          send(parent, {:stale, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      schedule
      |> Ash.Changeset.for_update(:disable, %{})
      |> Ash.update(actor: actor)
    end)

    {checked, stale} = ScheduleHealthWorker.run_check()

    assert checked >= 1
    assert stale >= 1

    assert_received_stale(job_key)
  end

  defp assert_received_stale(job_key) do
    receive do
      {:stale, measurements, metadata} ->
        if metadata.job_key == job_key do
          assert measurements.count == 1
          assert measurements.interval_seconds == 300
          assert measurements.seconds_since_enqueue > 600
        else
          assert_received_stale(job_key)
        end
    after
      0 ->
        flunk("expected stale telemetry for #{job_key}")
    end
  end

  defp ensure_identity_schedule(actor) do
    job_key = JobSchedule.identity_reconciliation_job_key()

    case JobSchedule.get_by_job_key(job_key, actor: actor) do
      {:ok, %JobSchedule{} = schedule} ->
        schedule

      _ ->
        JobSchedule
        |> Ash.Changeset.for_create(:create, %{
          job_key: job_key,
          cron: JobSchedule.identity_reconciliation_cron(),
          timezone: "Etc/UTC",
          args: %{},
          enabled: true,
          unique_period_seconds: 300
        })
        |> Ash.create!(actor: actor)
    end
  end
end
