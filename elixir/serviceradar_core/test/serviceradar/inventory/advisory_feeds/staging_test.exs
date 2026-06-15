defmodule ServiceRadar.Inventory.AdvisoryFeeds.StagingTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Staging

  setup do
    root = Path.join(System.tmp_dir!(), "advisory-staging-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "volume_available? is true for a writable dir, false for an unwritable one", %{root: root} do
    assert Staging.volume_available?(root)
    refute Staging.volume_available?("/proc/serviceradar-cannot-write-here")
  end

  test "prepare_run creates the per-run layout", %{root: root} do
    assert {:ok, paths} = Staging.prepare_run("nist-nvd2", "run-1", root)
    assert File.dir?(paths.extracted_dir)
    assert paths.download_path =~ "download.zip"
    assert paths.run_dir =~ Path.join("nist-nvd2", "run-1")
  end

  test "cleanup_run removes the per-run dir", %{root: root} do
    {:ok, paths} = Staging.prepare_run("cisa-kev", "run-2", root)
    assert File.dir?(paths.run_dir)
    assert :ok = Staging.cleanup_run(paths.run_dir)
    refute File.exists?(paths.run_dir)
  end

  test "reap_orphans removes only dirs older than the window", %{root: root} do
    {:ok, old} = Staging.prepare_run("nist-nvd2", "old-run", root)
    {:ok, fresh} = Staging.prepare_run("nist-nvd2", "fresh-run", root)

    now = System.system_time(:second)
    # Backdate the "old" run two days.
    old_mtime = now - 2 * 24 * 60 * 60
    File.touch!(old.run_dir, old_mtime)

    assert {:ok, reaped} =
             Staging.reap_orphans(root: root, now: now, max_age_seconds: 24 * 60 * 60)

    assert reaped >= 1
    refute File.exists?(old.run_dir)
    assert File.exists?(fresh.run_dir)
  end
end
