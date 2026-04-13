defmodule ServiceRadar.Integrations.ArmisNorthboundScheduleWorkerTest.SupportStub do
  @moduledoc false

  def available?, do: Process.get(:support_available, false)
  def prefix, do: "platform"

  def safe_insert(job) do
    send(Process.get(:test_pid), {:safe_insert, job})
    {:ok, job}
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundScheduleWorkerTest.SourceStub do
  @moduledoc false

  def list_by_type(:armis, actor: _actor) do
    {:ok,
     [
       %{
         id: "source-due",
         enabled: true,
         northbound_enabled: true,
         northbound_interval_seconds: 300,
         northbound_last_run_at: ~U[2026-04-13 11:50:00Z],
         endpoint: "https://armis.example",
         custom_fields: ["availability"],
         credentials: %{api_key: "key", api_secret: "secret"}
       },
       %{
         id: "source-future",
         enabled: true,
         northbound_enabled: true,
         northbound_interval_seconds: 600,
         northbound_last_run_at: ~U[2026-04-13 11:55:30Z],
         endpoint: "https://armis.example",
         custom_fields: ["availability"],
         credentials: %{api_key: "key", api_secret: "secret"}
       },
       %{
         id: "source-disabled",
         enabled: true,
         northbound_enabled: false,
         northbound_interval_seconds: 300,
         endpoint: "https://armis.example",
         custom_fields: ["availability"],
         credentials: %{api_key: "key", api_secret: "secret"}
       },
       %{
         id: "source-invalid",
         enabled: true,
         northbound_enabled: true,
         northbound_interval_seconds: 300,
         endpoint: "https://armis.example",
         custom_fields: [],
         credentials: %{api_key: "key", api_secret: "secret"}
       },
       %{
         id: "source-paused",
         enabled: false,
         northbound_enabled: true,
         northbound_interval_seconds: 300,
         endpoint: "https://armis.example",
         custom_fields: ["availability"],
         credentials: %{api_key: "key", api_secret: "secret"}
       }
     ]}
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundScheduleWorkerTest.RunWorkerStub do
  @moduledoc false

  def enqueue_recurring(source_id, opts) do
    send(Process.get(:test_pid), {:enqueue_recurring, source_id, opts})
    {:ok, %{source_id: source_id, opts: opts}}
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundScheduleWorkerTest.RunnerStub do
  @moduledoc false

  def northbound_ready?(%{custom_fields: []}), do: {:error, :missing_custom_field}
  def northbound_ready?(_source), do: :ok
end

defmodule ServiceRadar.Integrations.ArmisNorthboundScheduleWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Integrations.ArmisNorthboundScheduleWorker

  setup do
    Process.put(:test_pid, self())

    original = %{
      source: Application.get_env(:serviceradar_core, :armis_northbound_source_module),
      run_worker: Application.get_env(:serviceradar_core, :armis_northbound_run_worker_module),
      runner: Application.get_env(:serviceradar_core, :armis_northbound_runner),
      support: Application.get_env(:serviceradar_core, :armis_northbound_oban_support_module),
      active_job_exists:
        Application.get_env(:serviceradar_core, :armis_northbound_active_job_exists_fun),
      now_fun: Application.get_env(:serviceradar_core, :armis_northbound_schedule_now_fun),
      scheduler_interval:
        Application.get_env(:serviceradar_core, :armis_northbound_scheduler_interval_seconds)
    }

    Application.put_env(
      :serviceradar_core,
      :armis_northbound_source_module,
      ServiceRadar.Integrations.ArmisNorthboundScheduleWorkerTest.SourceStub
    )

    Application.put_env(
      :serviceradar_core,
      :armis_northbound_run_worker_module,
      ServiceRadar.Integrations.ArmisNorthboundScheduleWorkerTest.RunWorkerStub
    )

    Application.put_env(
      :serviceradar_core,
      :armis_northbound_runner,
      ServiceRadar.Integrations.ArmisNorthboundScheduleWorkerTest.RunnerStub
    )

    Application.put_env(
      :serviceradar_core,
      :armis_northbound_oban_support_module,
      ServiceRadar.Integrations.ArmisNorthboundScheduleWorkerTest.SupportStub
    )

    Application.put_env(
      :serviceradar_core,
      :armis_northbound_schedule_now_fun,
      fn -> ~U[2026-04-13 12:00:00Z] end
    )

    Application.put_env(:serviceradar_core, :armis_northbound_scheduler_interval_seconds, 45)

    on_exit(fn ->
      restore_env(:armis_northbound_source_module, original.source)
      restore_env(:armis_northbound_run_worker_module, original.run_worker)
      restore_env(:armis_northbound_runner, original.runner)
      restore_env(:armis_northbound_oban_support_module, original.support)
      restore_env(:armis_northbound_active_job_exists_fun, original.active_job_exists)
      restore_env(:armis_northbound_schedule_now_fun, original.now_fun)
      restore_env(:armis_northbound_scheduler_interval_seconds, original.scheduler_interval)
      Process.delete(:support_available)
      Process.delete(:test_pid)
    end)

    :ok
  end

  test "ensure_scheduled returns oban_unavailable when Oban is unavailable" do
    Process.put(:support_available, false)
    assert {:error, :oban_unavailable} = ArmisNorthboundScheduleWorker.ensure_scheduled()
  end

  test "perform enqueues due recurring runs and reschedules reconciliation" do
    Process.put(:support_available, true)

    Application.put_env(:serviceradar_core, :armis_northbound_active_job_exists_fun, fn
      _worker, %{"integration_source_id" => "source-future", "manual" => false} -> true
      _worker, _args_filter -> false
    end)

    assert :ok = ArmisNorthboundScheduleWorker.perform(%Oban.Job{})

    assert_received {:enqueue_recurring, "source-due", [schedule_in: 0]}
    refute_received {:enqueue_recurring, "source-future", _}
    refute_received {:enqueue_recurring, "source-disabled", _}
    refute_received {:enqueue_recurring, "source-invalid", _}
    refute_received {:enqueue_recurring, "source-paused", _}

    assert_received {:safe_insert, scheduler_job}
    assert %Ecto.Changeset{} = scheduler_job
    assert scheduler_job.changes.args == %{}

    assert DateTime.diff(scheduler_job.changes.scheduled_at, DateTime.utc_now(), :second) in 44..46
  end

  test "seconds_until_next returns remaining delay from last run and interval" do
    source = %{
      northbound_interval_seconds: 600,
      northbound_last_run_at: ~U[2026-04-13 11:55:30Z]
    }

    assert 330 =
             ArmisNorthboundScheduleWorker.seconds_until_next(source, ~U[2026-04-13 12:00:00Z])

    assert 0 =
             ArmisNorthboundScheduleWorker.seconds_until_next(
               %{northbound_interval_seconds: 600},
               ~U[2026-04-13 12:00:00Z]
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
