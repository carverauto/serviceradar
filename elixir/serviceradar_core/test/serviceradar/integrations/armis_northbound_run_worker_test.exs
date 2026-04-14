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

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.SourceLookup do
  @moduledoc false
  def get_by_id(id, actor: _actor), do: {:ok, %{id: id}}
end

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.SupportStub do
  @moduledoc false

  def available?, do: Process.get(:support_available, false)

  def safe_insert(job) do
    send(Process.get(:test_pid), {:safe_insert, job})
    {:ok, job}
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Integrations.ArmisNorthboundRunWorker
  alias ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.SourceLookup

  test "enqueue_now returns oban_unavailable when Oban is not running" do
    assert {:error, :oban_unavailable} =
             ArmisNorthboundRunWorker.enqueue_now(Ecto.UUID.generate())
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

  test "perform returns error when runner reports failure" do
    source_id = Ecto.UUID.generate()

    with_env(
      ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.RunnerFailure,
      SourceLookup,
      fn ->
        job = %Oban.Job{id: 9, args: %{"integration_source_id" => source_id}}
        assert {:error, :northbound_run_failed} = ArmisNorthboundRunWorker.perform(job)
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

    Application.put_env(
      :serviceradar_core,
      :armis_northbound_oban_support_module,
      ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.SupportStub
    )

    try do
      fun.()
    after
      restore_env(:armis_northbound_oban_support_module, original_support)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
