defmodule ServiceRadar.Monitoring.PollJobIntegrationTest do
  @moduledoc """
  Integration tests for the full polling flow using PollJob state machine.

  Verifies that:
  - PollJob resources can be created with proper state
  - State machine transitions work correctly
  - PollJob tracks execution progress
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.PollingSchedule
  alias ServiceRadar.Monitoring.PollJob

  @moduletag :database

  setup do
    unique_id = :erlang.unique_integer([:positive])
    actor = SystemActor.system(:test)

    # Create a valid polling schedule for the tests
    {:ok, schedule} =
      PollingSchedule
      |> Ash.Changeset.for_create(:create, %{
        name: "Test Schedule #{unique_id}",
        schedule_type: :interval,
        interval_seconds: 60
      })
      |> Ash.create()

    {:ok,
     actor: actor,
     unique_id: unique_id,
     schedule_id: schedule.id,
     schedule: schedule}
  end

  describe "PollJob lifecycle" do
    test "creates job in pending state", %{schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Test Schedule",
          check_count: 3,
          check_ids: [Ash.UUID.generate(), Ash.UUID.generate(), Ash.UUID.generate()],
          priority: 1,
          timeout_seconds: 60
        })
        |> Ash.create()

      assert job.status == :pending
      assert job.schedule_id == schedule_id
      assert job.check_count == 3
    end

    test "transitions pending -> dispatching -> running -> completed", %{schedule_id: schedule_id} do
      # Create job
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Transition Test",
          check_count: 2
        })
        |> Ash.create()

      assert job.status == :pending

      # Transition to dispatching
      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{})
        |> Ash.update()

      assert dispatching.status == :dispatching
      assert dispatching.dispatched_at != nil

      # Transition to running
      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{agent_id: "agent-001"})
        |> Ash.update()

      assert running.status == :running
      assert running.started_at != nil
      assert running.agent_id == "agent-001"

      # Complete the job
      {:ok, completed} =
        running
        |> Ash.Changeset.for_update(:complete, %{
          success_count: 2,
          failure_count: 0,
          results: [%{check_id: "c1", status: "ok"}, %{check_id: "c2", status: "ok"}]
        })
        |> Ash.update()

      assert completed.status == :completed
      assert completed.completed_at != nil
      assert completed.success_count == 2
      assert completed.failure_count == 0
      assert completed.duration_ms != nil
      assert completed.duration_ms > 0
    end

    test "can transition to failed from dispatching", %{schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Fail Dispatch Test",
          check_count: 1
        })
        |> Ash.create()

      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{})
        |> Ash.update()

      {:ok, failed} =
        dispatching
        |> Ash.Changeset.for_update(:fail, %{
          error_message: "No gateway available",
          error_code: "NO_GATEWAY"
        })
        |> Ash.update()

      assert failed.status == :failed
      assert failed.error_message == "No gateway available"
      assert failed.error_code == "NO_GATEWAY"
    end

    test "can transition to failed from running", %{schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Fail Running Test",
          check_count: 1
        })
        |> Ash.create()

      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{})
        |> Ash.update()

      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      {:ok, failed} =
        running
        |> Ash.Changeset.for_update(:fail, %{
          error_message: "Agent connection lost",
          error_code: "AGENT_DISCONNECTED"
        })
        |> Ash.update()

      assert failed.status == :failed
      assert failed.error_message == "Agent connection lost"
    end

    test "can transition to timeout from running", %{schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Timeout Test",
          check_count: 1
        })
        |> Ash.create()

      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{})
        |> Ash.update()

      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      {:ok, timed_out} =
        running
        |> Ash.Changeset.for_update(:timeout, %{})
        |> Ash.update()

      assert timed_out.status == :timeout
      assert timed_out.error_message == "Job execution timed out"
    end

    test "can cancel pending job", %{schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Cancel Test",
          check_count: 1
        })
        |> Ash.create()

      {:ok, cancelled} =
        job
        |> Ash.Changeset.for_update(:cancel, %{reason: "User requested cancellation"})
        |> Ash.update()

      assert cancelled.status == :cancelled
      assert cancelled.error_message == "User requested cancellation"
    end

    test "can retry failed job", %{schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Retry Test",
          check_count: 1
        })
        |> Ash.create()

      # Run through to failure
      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{})
        |> Ash.update()

      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      {:ok, failed} =
        running
        |> Ash.Changeset.for_update(:fail, %{error_message: "First attempt failed"})
        |> Ash.update()

      assert failed.retry_count == 0

      # Retry
      {:ok, retrying} =
        failed
        |> Ash.Changeset.for_update(:retry, %{})
        |> Ash.update()

      assert retrying.status == :pending
      assert retrying.retry_count == 1
      assert retrying.error_message == nil
      assert retrying.started_at == nil
    end
  end

  describe "PollJob queries" do
    setup %{schedule_id: schedule_id} do
      # Create jobs in different states
      {:ok, pending_job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Pending Query Job",
          check_count: 1
        })
        |> Ash.create()

      {:ok, running_job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Running Query Job",
          check_count: 1
        })
        |> Ash.create()

      {:ok, running_job} =
        running_job
        |> Ash.Changeset.for_update(:dispatch, %{})
        |> Ash.update()

      {:ok, running_job} =
        running_job
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      {:ok, pending_job: pending_job, running_job: running_job}
    end

    test "pending query returns only pending jobs", %{pending_job: pending, running_job: running} do
      jobs =
        PollJob
        |> Ash.Query.for_read(:pending, %{})
        |> Ash.read!(actor: actor)

      assert Enum.any?(jobs, &(&1.id == pending.id))
      refute Enum.any?(jobs, &(&1.id == running.id))
    end

    test "running query returns only running jobs", %{pending_job: pending, running_job: running} do
      jobs =
        PollJob
        |> Ash.Query.for_read(:running, %{})
        |> Ash.read!(actor: actor)

      assert Enum.any?(jobs, &(&1.id == running.id))
      refute Enum.any?(jobs, &(&1.id == pending.id))
    end

    test "by_schedule returns jobs for a schedule", %{schedule_id: schedule_id, pending_job: pending} do
      jobs =
        PollJob
        |> Ash.Query.for_read(:by_schedule, %{schedule_id: schedule_id})
        |> Ash.read!(actor: actor)

      assert Enum.any?(jobs, &(&1.id == pending.id))
    end
  end

  describe "calculations" do
    test "is_terminal calculation works", %{schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Terminal Test",
          check_count: 1
        })
        |> Ash.create()
        |> then(fn {:ok, job} ->
          Ash.load(job, [:is_terminal])
        end)

      # Pending is not terminal
      assert job.is_terminal == false

      # Complete it
      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{})
        |> Ash.update()

      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      {:ok, completed} =
        running
        |> Ash.Changeset.for_update(:complete, %{success_count: 1})
        |> Ash.update()
        |> then(fn {:ok, job} ->
          Ash.load(job, [:is_terminal])
        end)

      # Completed is terminal
      assert completed.is_terminal == true
    end

    test "can_retry calculation works", %{schedule_id: schedule_id} do
      # Default max_retries is 3, so we can test with that
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Can Retry Test",
          check_count: 1
        })
        |> Ash.create()

      # Fail the job
      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{})
        |> Ash.update()

      {:ok, failed} =
        dispatching
        |> Ash.Changeset.for_update(:fail, %{error_message: "Error"})
        |> Ash.update()
        |> then(fn {:ok, job} ->
          Ash.load(job, [:can_retry])
        end)

      # retry_count = 0, max_retries = 3, so can_retry should be true
      assert failed.can_retry == true
      assert failed.retry_count == 0
    end
  end
end
