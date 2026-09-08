defmodule ServiceRadar.Inventory.AdvisoryFeeds.StagingCleanupWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Staging
  alias ServiceRadar.Inventory.AdvisoryFeeds.StagingCleanupWorker

  setup do
    root = Path.join(System.tmp_dir!(), "advisory-cleanup-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "run_cleanup with nist_keep 0 drops every nist-nvd2 run", %{root: root} do
    {:ok, one} = Staging.prepare_run("nist-nvd2", "one", root)
    {:ok, two} = Staging.prepare_run("nist-nvd2", "two", root)

    assert %{removed_dirs: 2, nist_keep: 0} =
             StagingCleanupWorker.run_cleanup(root: root, nist_keep: 0)

    refute File.exists?(one.run_dir)
    refute File.exists?(two.run_dir)
  end

  test "run_cleanup with nist_keep 1 keeps only the newest nist-nvd2 run", %{root: root} do
    {:ok, older} = Staging.prepare_run("nist-nvd2", "older", root)
    {:ok, newer} = Staging.prepare_run("nist-nvd2", "newer", root)
    File.touch!(older.run_dir, System.system_time(:second) - 60)

    assert %{removed_dirs: removed, nist_keep: 1} =
             StagingCleanupWorker.run_cleanup(root: root, nist_keep: 1)

    assert removed >= 1
    refute File.exists?(older.run_dir)
    assert File.exists?(newer.run_dir)
  end

  test "run_cleanup applies the same executing-aware bound to Ubuntu", %{root: root} do
    {:ok, older} = Staging.prepare_run("ubuntu-osv-vex", "older", root)
    {:ok, newer} = Staging.prepare_run("ubuntu-osv-vex", "newer", root)
    File.touch!(older.run_dir, System.system_time(:second) - 60)

    assert %{removed_dirs: removed, ubuntu_keep: 1} =
             StagingCleanupWorker.run_cleanup(
               root: root,
               nist_keep: 0,
               ubuntu_keep: 1
             )

    assert removed >= 1
    refute File.exists?(older.run_dir)
    assert File.exists?(newer.run_dir)
  end

  test "reschedule_seconds is at least one minute" do
    assert StagingCleanupWorker.reschedule_seconds() >= 60
  end
end
