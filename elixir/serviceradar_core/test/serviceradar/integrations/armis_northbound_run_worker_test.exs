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

defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Integrations.ArmisNorthboundRunWorker
  alias ServiceRadar.Integrations.ArmisNorthboundRunWorkerTest.SourceLookup

  test "enqueue_now returns oban_unavailable when Oban is not running" do
    assert {:error, :oban_unavailable} =
             ArmisNorthboundRunWorker.enqueue_now(Ecto.UUID.generate())
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
