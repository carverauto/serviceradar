defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.RunnerSuccess do
  @moduledoc false
  def run_for_source(source, opts) do
    send(Process.get(:test_pid), {:runner_called, source.id, opts})
    {:ok, %{result: :success}}
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.RunnerFailure do
  @moduledoc false
  def run_for_source(_source, _opts) do
    {:error, %{result: :failed}}
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.RunnerAuthFailure do
  @moduledoc false
  def run_for_source(_source, _opts) do
    {:error,
     %{
       result: %{
         updated_count: 0,
         error_count: 1,
         errors: [%{reason: {:unexpected_status, 401, %{"message" => "Invalid access token."}}}],
         error_message: "Invalid access token."
       }
     }}
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.RunnerPartialAuthFailure do
  @moduledoc false
  def run_for_source(_source, _opts) do
    {:error,
     %{
       result: %{
         updated_count: 3,
         error_count: 1,
         errors: [%{reason: {:unexpected_status, 401, %{"message" => "Invalid access token."}}}],
         error_message: "Invalid access token."
       }
     }}
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.SourceLookup do
  @moduledoc false
  def get_by_id(id, actor: _actor), do: {:ok, %{id: id}}
end

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.SupportStub do
  @moduledoc false

  def available?, do: Process.get(:support_available, false)
  def prefix, do: "platform"

  def safe_insert(job, opts \\ []) do
    send(Process.get(:test_pid), {:safe_insert, job})
    send(Process.get(:test_pid), {:safe_insert_opts, opts})

    case Process.get(:safe_insert_results) do
      [result | remaining] ->
        Process.put(:safe_insert_results, remaining)
        result

      _ ->
        {:ok, job}
    end
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Integrations.ArmisNorthboundRunWorker
  alias ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.SourceLookup

  test "enqueue_now returns oban_unavailable when Oban is not running" do
    with_support(fn ->
      assert {:error, :oban_unavailable} =
               ArmisNorthboundRunWorker.enqueue_now(Ecto.UUID.generate())
    end)
  end

  test "enqueue_recurring inserts a non-manual scheduled job when Oban is available" do
    Process.put(:test_pid, self())

    with_support(fn ->
      Process.put(:support_available, true)

      assert {:ok, %Ecto.Changeset{} = job} =
               ArmisNorthboundRunWorker.enqueue_recurring("source-123", schedule_in: 90)

      assert job.changes.args == %{"integration_source_id" => "source-123", "manual" => false}
      assert_received {:safe_insert, ^job}
      assert DateTime.diff(job.changes.scheduled_at, DateTime.utc_now(), :second) in 89..91
    end)
  after
    Process.delete(:support_available)
    Process.delete(:test_pid)
  end

  test "enqueue_now bumps an existing scheduled conflict to run immediately" do
    Process.put(:test_pid, self())

    with_support(fn ->
      Process.put(:support_available, true)

      assert {:ok, %Ecto.Changeset{} = job} =
               ArmisNorthboundRunWorker.enqueue_now("source-123")

      assert job.changes.args == %{"integration_source_id" => "source-123", "manual" => true}

      assert job.changes.replace == [
               scheduled: [:args, :scheduled_at],
               available: [:args],
               retryable: [:args, :scheduled_at]
             ]

      # scheduled_at MUST be present in the changeset changes, otherwise the
      # `replace: [scheduled: [..., :scheduled_at]]` cannot bump an already
      # `scheduled` recurring job to run now (Oban copies replace keys from
      # changeset.changes), and "Run now" would silently wait for the next
      # hourly run.
      assert %DateTime{} = job.changes.scheduled_at
      assert DateTime.diff(DateTime.utc_now(), job.changes.scheduled_at, :second) in 0..3

      assert_received {:safe_insert, ^job}
    end)
  after
    Process.delete(:support_available)
    Process.delete(:test_pid)
  end

  test "enqueue_now reaps stale executing source jobs before inserting" do
    Process.put(:test_pid, self())

    with_support(fn ->
      Process.put(:support_available, true)
      Application.put_env(:serviceradar_core, :armis_northbound_stale_run_cutoff_seconds, 240)

      Application.put_env(:serviceradar_core, :armis_northbound_reap_stale_jobs_fun, fn
        worker, source_id, now, cutoff_seconds ->
          send(self(), {:reap_stale_jobs, worker, source_id, now, cutoff_seconds})
          {1, nil}
      end)

      assert {:ok, %Ecto.Changeset{} = job} =
               ArmisNorthboundRunWorker.enqueue_now("source-123")

      assert_received {:reap_stale_jobs, ArmisNorthboundRunWorker, "source-123", %DateTime{}, 240}

      assert_received {:safe_insert, ^job}
      assert_received {:safe_insert_opts, [stale_conflict_cutoff_seconds: 240]}
    end)
  after
    Process.delete(:support_available)
    Process.delete(:test_pid)
  end

  test "perform delegates to configured source module and runner" do
    source_id = Ecto.UUID.generate()
    Process.put(:test_pid, self())

    with_env(
      ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.RunnerSuccess,
      SourceLookup,
      fn ->
        job = %Oban.Job{id: 42, args: %{"integration_source_id" => source_id, "manual" => true}}
        assert :ok = ArmisNorthboundRunWorker.perform(job)
      end
    )

    assert_received {:runner_called, ^source_id, opts}
    assert opts[:oban_job_id] == 42
    assert opts[:manual?] == true
    assert match?(%{role: :system}, opts[:actor])
  after
    Process.delete(:test_pid)
  end

  test "perform treats recorded runner failure as handled" do
    source_id = Ecto.UUID.generate()

    with_env(
      ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.RunnerFailure,
      SourceLookup,
      fn ->
        job = %Oban.Job{id: 9, args: %{"integration_source_id" => source_id}}
        assert :ok = ArmisNorthboundRunWorker.perform(job)
      end
    )
  end

  test "perform surfaces a total auth failure to Oban so the job retries and alerts" do
    source_id = Ecto.UUID.generate()

    with_env(
      ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.RunnerAuthFailure,
      SourceLookup,
      fn ->
        job = %Oban.Job{id: 11, args: %{"integration_source_id" => source_id}}

        assert {:error, {:armis_northbound_auth_failed, "Invalid access token."}} =
                 ArmisNorthboundRunWorker.perform(job)
      end
    )
  end

  test "perform does not retry a partial run that also hit an auth error" do
    source_id = Ecto.UUID.generate()

    with_env(
      ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.RunnerPartialAuthFailure,
      SourceLookup,
      fn ->
        job = %Oban.Job{id: 12, args: %{"integration_source_id" => source_id}}
        assert :ok = ArmisNorthboundRunWorker.perform(job)
      end
    )
  end

  defp with_env(runner_module, source_module, fun) do
    original_runner = Application.get_env(:serviceradar_core, :armis_northbound_runner)
    original_source = Application.get_env(:serviceradar_core, :armis_northbound_source_module)

    Application.put_env(:serviceradar_core, :armis_northbound_runner, runner_module)
    Application.put_env(:serviceradar_core, :armis_northbound_source_module, source_module)

    try do
      fun.()
    after
      restore_env(:armis_northbound_runner, original_runner)
      restore_env(:armis_northbound_source_module, original_source)
    end
  end

  defp with_support(fun) do
    original_support =
      Application.get_env(:serviceradar_core, :armis_northbound_oban_support_module)

    original_reap_stale_jobs =
      Application.get_env(:serviceradar_core, :armis_northbound_reap_stale_jobs_fun)

    original_stale_cutoff =
      Application.get_env(:serviceradar_core, :armis_northbound_stale_run_cutoff_seconds)

    Application.put_env(
      :serviceradar_core,
      :armis_northbound_oban_support_module,
      ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.SupportStub
    )

    try do
      fun.()
    after
      restore_env(:armis_northbound_oban_support_module, original_support)
      restore_env(:armis_northbound_reap_stale_jobs_fun, original_reap_stale_jobs)
      restore_env(:armis_northbound_stale_run_cutoff_seconds, original_stale_cutoff)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
