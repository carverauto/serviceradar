defmodule ServiceRadar.Inventory.DeviceCleanupSettingsActionTest do
  @moduledoc """
  Action-level tests for DeviceCleanupSettings.run_cleanup.

  Verifies the generic action returns {:ok, %{scheduled: true}}, enqueues a
  DeviceCleanupWorker job, and that a manual run lands independently of a
  pre-existing scheduled job (so clicking "Run cleanup now" is not silently
  swallowed by uniqueness when the daily job is pending).
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    delete_worker_jobs()
    actor = SystemActor.system(:device_cleanup_settings_action_test)
    {:ok, actor: actor}
  end

  test "run_cleanup returns {:ok, %{scheduled: true}} and inserts a manual job", %{actor: actor} do
    assert {:ok, %{scheduled: true}} = DeviceCleanupSettings.run_cleanup(actor: actor)

    assert [%Oban.Job{args: %{"manual" => true}}] = manual_jobs()
  end

  test "manual run enqueues independently of a pre-existing scheduled job", %{actor: actor} do
    # Insert a scheduled job the way ensure_scheduled does; it may be :already_scheduled
    # if one lingered — the delete in setup clears both, so this creates a fresh one.
    assert {:ok, _} = DeviceCleanupWorker.ensure_scheduled()

    # Both the scheduled job and the manual job land in the queue.
    assert {:ok, %{scheduled: true}} = DeviceCleanupSettings.run_cleanup(actor: actor)

    all = worker_jobs()
    assert length(all) >= 2
    assert Enum.any?(all, &(Map.get(&1.args, "manual") == true))
    assert Enum.any?(all, &(Map.get(&1.args, "manual") != true))
  end

  # --- helpers ---

  defp worker_jobs do
    name = Oban.Worker.to_string(DeviceCleanupWorker)
    Repo.all(from(j in Oban.Job, where: j.worker == ^name))
  end

  defp manual_jobs do
    name = Oban.Worker.to_string(DeviceCleanupWorker)

    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^name and fragment("? @> ?::jsonb", j.args, ^%{"manual" => true})
      )
    )
  end

  defp delete_worker_jobs do
    name = Oban.Worker.to_string(DeviceCleanupWorker)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == ^name))
  end
end
