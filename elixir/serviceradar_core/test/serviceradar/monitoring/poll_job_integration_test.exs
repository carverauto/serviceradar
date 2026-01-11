defmodule ServiceRadar.Monitoring.PollJobIntegrationTest do
  @moduledoc """
  Integration tests for the full polling flow using PollJob state machine.

  Verifies that:
  - PollJob resources can be created with proper state
  - State machine transitions work correctly
  - PollJob tracks execution progress
  - Multi-tenant isolation works for poll jobs
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Monitoring.PollJob
  alias ServiceRadar.Monitoring.PollingSchedule

  @moduletag :database

  setup_all do
    tenant_a = ServiceRadar.TestSupport.create_tenant_schema!("poll-job-a")
    tenant_b = ServiceRadar.TestSupport.create_tenant_schema!("poll-job-b")

    on_exit(fn ->
      ServiceRadar.TestSupport.drop_tenant_schema!(tenant_a.tenant_slug)
      ServiceRadar.TestSupport.drop_tenant_schema!(tenant_b.tenant_slug)
    end)

    {:ok, tenant_a_id: tenant_a.tenant_id, tenant_b_id: tenant_b.tenant_id}
  end

  setup %{tenant_a_id: tenant_a_id} do
    unique_id = :erlang.unique_integer([:positive])

    actor = %{
      id: Ash.UUID.generate(),
      email: "test@serviceradar.local",
      role: :super_admin,
      tenant_id: tenant_a_id
    }

    # Create a valid polling schedule for the tests
    {:ok, schedule} =
      PollingSchedule
      |> Ash.Changeset.for_create(:create, %{
        name: "Test Schedule #{unique_id}",
        schedule_type: :interval,
        interval_seconds: 60
      }, tenant: tenant_a_id, authorize?: false)
      |> Ash.create()

    {:ok,
     tenant_id: tenant_a_id,
     actor: actor,
     unique_id: unique_id,
     schedule_id: schedule.id,
     schedule: schedule}
  end

  describe "PollJob lifecycle" do
    test "creates job in pending state", %{tenant_id: tenant_id, schedule_id: schedule_id, unique_id: _unique_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Test Schedule",
          check_count: 3,
          check_ids: [Ash.UUID.generate(), Ash.UUID.generate(), Ash.UUID.generate()],
          priority: 1,
          timeout_seconds: 60
        }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert job.status == :pending
      assert job.schedule_id == schedule_id
      assert job.check_count == 3
      assert job.tenant_id == tenant_id
    end

    test "transitions pending -> dispatching -> running -> completed", %{
      tenant_id: tenant_id,
      schedule_id: schedule_id
    } do
      # Create job
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Transition Test",
          check_count: 2
        }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert job.status == :pending

      # Transition to dispatching
      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{}, authorize?: false)
        |> Ash.update()

      assert dispatching.status == :dispatching
      assert dispatching.dispatched_at != nil

      # Transition to running
      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{agent_id: "agent-001"}, authorize?: false)
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
        }, authorize?: false)
        |> Ash.update()

      assert completed.status == :completed
      assert completed.completed_at != nil
      assert completed.success_count == 2
      assert completed.failure_count == 0
      assert completed.duration_ms != nil
      assert completed.duration_ms > 0
    end

    test "can transition to failed from dispatching", %{tenant_id: tenant_id, schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Fail Dispatch Test",
          check_count: 1
        }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{}, authorize?: false)
        |> Ash.update()

      {:ok, failed} =
        dispatching
        |> Ash.Changeset.for_update(:fail, %{
          error_message: "No gateway available",
          error_code: "NO_GATEWAY"
        }, authorize?: false)
        |> Ash.update()

      assert failed.status == :failed
      assert failed.error_message == "No gateway available"
      assert failed.error_code == "NO_GATEWAY"
    end

    test "can transition to failed from running", %{tenant_id: tenant_id, schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Fail Running Test",
          check_count: 1
        }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{}, authorize?: false)
        |> Ash.update()

      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{}, authorize?: false)
        |> Ash.update()

      {:ok, failed} =
        running
        |> Ash.Changeset.for_update(:fail, %{
          error_message: "Agent connection lost",
          error_code: "AGENT_DISCONNECTED"
        }, authorize?: false)
        |> Ash.update()

      assert failed.status == :failed
      assert failed.error_message == "Agent connection lost"
    end

    test "can transition to timeout from running", %{tenant_id: tenant_id, schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Timeout Test",
          check_count: 1,
          }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{}, authorize?: false)
        |> Ash.update()

      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{}, authorize?: false)
        |> Ash.update()

      {:ok, timed_out} =
        running
        |> Ash.Changeset.for_update(:timeout, %{}, authorize?: false)
        |> Ash.update()

      assert timed_out.status == :timeout
      assert timed_out.error_message == "Job execution timed out"
    end

    test "can cancel pending job", %{tenant_id: tenant_id, schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Cancel Test",
          check_count: 1,
          }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, cancelled} =
        job
        |> Ash.Changeset.for_update(:cancel, %{reason: "User requested cancellation"}, authorize?: false)
        |> Ash.update()

      assert cancelled.status == :cancelled
      assert cancelled.error_message == "User requested cancellation"
    end

    test "can retry failed job", %{tenant_id: tenant_id, schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Retry Test",
          check_count: 1,
          }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      # Run through to failure
      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{}, authorize?: false)
        |> Ash.update()

      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{}, authorize?: false)
        |> Ash.update()

      {:ok, failed} =
        running
        |> Ash.Changeset.for_update(:fail, %{error_message: "First attempt failed"}, authorize?: false)
        |> Ash.update()

      assert failed.retry_count == 0

      # Retry
      {:ok, retrying} =
        failed
        |> Ash.Changeset.for_update(:retry, %{}, authorize?: false)
        |> Ash.update()

      assert retrying.status == :pending
      assert retrying.retry_count == 1
      assert retrying.error_message == nil
      assert retrying.started_at == nil
    end
  end

  describe "PollJob queries" do
    setup %{tenant_id: tenant_id, schedule_id: schedule_id} do
      # Create jobs in different states
      {:ok, pending_job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Pending Query Job",
          check_count: 1,
          }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, running_job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Running Query Job",
          check_count: 1,
          }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, running_job} =
        running_job
        |> Ash.Changeset.for_update(:dispatch, %{}, authorize?: false)
        |> Ash.update()

      {:ok, running_job} =
        running_job
        |> Ash.Changeset.for_update(:start, %{}, authorize?: false)
        |> Ash.update()

      {:ok, pending_job: pending_job, running_job: running_job}
    end

    test "pending query returns only pending jobs", %{pending_job: pending, running_job: running, tenant_id: tenant_id} do
      jobs =
        PollJob
        |> Ash.Query.for_read(:pending, %{}, tenant: tenant_id)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(jobs, &(&1.id == pending.id))
      refute Enum.any?(jobs, &(&1.id == running.id))
    end

    test "running query returns only running jobs", %{pending_job: pending, running_job: running, tenant_id: tenant_id} do
      jobs =
        PollJob
        |> Ash.Query.for_read(:running, %{}, tenant: tenant_id)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(jobs, &(&1.id == running.id))
      refute Enum.any?(jobs, &(&1.id == pending.id))
    end

    test "by_schedule returns jobs for a schedule", %{schedule_id: schedule_id, pending_job: pending, tenant_id: tenant_id} do
      jobs =
        PollJob
        |> Ash.Query.for_read(:by_schedule, %{schedule_id: schedule_id}, tenant: tenant_id)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(jobs, &(&1.id == pending.id))
    end
  end

  describe "multi-tenant isolation" do
    test "jobs are isolated by tenant", %{
      tenant_id: tenant_a_id,
      schedule_id: schedule_a_id,
      unique_id: unique_id,
      tenant_b_id: tenant_b_id
    } do
      # Create a schedule in tenant B
      {:ok, schedule_b} =
        PollingSchedule
        |> Ash.Changeset.for_create(:create, %{
          name: "Tenant B Schedule #{unique_id}",
          schedule_type: :interval,
          interval_seconds: 60
        }, tenant: tenant_b_id, authorize?: false)
        |> Ash.create()

      # Create job in tenant A
      {:ok, job_a} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_a_id,
          schedule_name: "Tenant A Job",
          check_count: 1
        }, tenant: tenant_a_id, authorize?: false)
        |> Ash.create()

      # Create job in tenant B
      {:ok, job_b} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_b.id,
          schedule_name: "Tenant B Job",
          check_count: 1
        }, tenant: tenant_b_id, authorize?: false)
        |> Ash.create()

      # Query tenant A - should only see tenant A's job
      jobs_a =
        PollJob
        |> Ash.Query.for_read(:read, %{}, tenant: tenant_a_id)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(jobs_a, &(&1.id == job_a.id))
      refute Enum.any?(jobs_a, &(&1.id == job_b.id))

      # Query tenant B - should only see tenant B's job
      jobs_b =
        PollJob
        |> Ash.Query.for_read(:read, %{}, tenant: tenant_b_id)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(jobs_b, &(&1.id == job_b.id))
      refute Enum.any?(jobs_b, &(&1.id == job_a.id))
    end
  end

  describe "calculations" do
    test "is_terminal calculation works", %{tenant_id: tenant_id, schedule_id: schedule_id} do
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Terminal Test",
          check_count: 1,
          }, tenant: tenant_id, authorize?: false)
        |> Ash.create()
        |> then(fn {:ok, job} ->
          Ash.load(job, [:is_terminal], authorize?: false)
        end)

      # Pending is not terminal
      assert job.is_terminal == false

      # Complete it
      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{}, authorize?: false)
        |> Ash.update()

      {:ok, running} =
        dispatching
        |> Ash.Changeset.for_update(:start, %{}, authorize?: false)
        |> Ash.update()

      {:ok, completed} =
        running
        |> Ash.Changeset.for_update(:complete, %{success_count: 1}, authorize?: false)
        |> Ash.update()
        |> then(fn {:ok, job} ->
          Ash.load(job, [:is_terminal], authorize?: false)
        end)

      # Completed is terminal
      assert completed.is_terminal == true
    end

    test "can_retry calculation works", %{tenant_id: tenant_id, schedule_id: schedule_id} do
      # Default max_retries is 3, so we can test with that
      {:ok, job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: schedule_id,
          schedule_name: "Can Retry Test",
          check_count: 1
        }, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      # Fail the job
      {:ok, dispatching} =
        job
        |> Ash.Changeset.for_update(:dispatch, %{}, authorize?: false)
        |> Ash.update()

      {:ok, failed} =
        dispatching
        |> Ash.Changeset.for_update(:fail, %{error_message: "Error"}, authorize?: false)
        |> Ash.update()
        |> then(fn {:ok, job} ->
          Ash.load(job, [:can_retry], authorize?: false)
        end)

      # retry_count = 0, max_retries = 3, so can_retry should be true
      assert failed.can_retry == true
      assert failed.retry_count == 0
    end
  end
end
