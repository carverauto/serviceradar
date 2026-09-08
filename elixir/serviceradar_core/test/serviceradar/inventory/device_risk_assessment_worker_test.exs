defmodule ServiceRadar.Inventory.DeviceRiskAssessmentWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.DeviceRiskAssessmentWorker

  @moduletag :db_free

  setup do
    previous = Application.get_env(:serviceradar_core, DeviceRiskAssessmentWorker, [])

    on_exit(fn ->
      Application.put_env(:serviceradar_core, DeviceRiskAssessmentWorker, previous)
    end)

    :ok
  end

  test "is a self-scheduling Oban worker" do
    {:module, _} = Code.ensure_loaded(DeviceRiskAssessmentWorker)
    assert function_exported?(DeviceRiskAssessmentWorker, :perform, 1)
    assert function_exported?(DeviceRiskAssessmentWorker, :ensure_scheduled, 0)
    assert function_exported?(DeviceRiskAssessmentWorker, :ensure_scheduled, 1)
    assert DeviceRiskAssessmentWorker.timeout(%Oban.Job{args: %{}}) == 840_000
  end

  test "perform applies scores and succeeds" do
    Application.put_env(:serviceradar_core, DeviceRiskAssessmentWorker,
      assess: fn opts ->
        assert opts == []
        {:ok, 3}
      end
    )

    assert :ok = DeviceRiskAssessmentWorker.perform(%Oban.Job{args: %{}})
  end

  test "perform reads reschedule_seconds from JSON string args" do
    Application.put_env(:serviceradar_core, DeviceRiskAssessmentWorker,
      assess: fn _opts -> {:ok, 0} end
    )

    assert :ok =
             DeviceRiskAssessmentWorker.perform(%Oban.Job{
               args: %{"reschedule_seconds" => "900"}
             })
  end

  test "perform returns the assessment error instead of swallowing it" do
    Application.put_env(:serviceradar_core, DeviceRiskAssessmentWorker,
      assess: fn _opts -> {:error, :nvd_unavailable} end
    )

    assert {:error, :nvd_unavailable} =
             DeviceRiskAssessmentWorker.perform(%Oban.Job{args: %{}})
  end

  test "perform fails when the assessor raises" do
    Application.put_env(:serviceradar_core, DeviceRiskAssessmentWorker,
      assess: fn _opts -> raise "boom" end
    )

    assert {:error, %RuntimeError{message: "boom"}} =
             DeviceRiskAssessmentWorker.perform(%Oban.Job{args: %{}})
  end
end
