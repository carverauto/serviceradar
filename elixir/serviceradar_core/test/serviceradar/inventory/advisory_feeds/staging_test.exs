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
    {:ok, old} = Staging.prepare_run("cisa-kev", "old-run", root)
    {:ok, fresh} = Staging.prepare_run("cisa-kev", "fresh-run", root)

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

  test "prune_feed keeps only the newest nist-nvd2 run", %{root: root} do
    {:ok, older} = Staging.prepare_run("nist-nvd2", "older", root)
    {:ok, newer} = Staging.prepare_run("nist-nvd2", "newer", root)
    File.touch!(older.run_dir, System.system_time(:second) - 60)

    assert {:ok, 1} = Staging.prune_feed("nist-nvd2", root: root, keep: 1)
    refute File.exists?(older.run_dir)
    assert File.exists?(newer.run_dir)
  end

  test "prune_feed keep 0 removes every nist-nvd2 run", %{root: root} do
    {:ok, one} = Staging.prepare_run("nist-nvd2", "one", root)
    {:ok, two} = Staging.prepare_run("nist-nvd2", "two", root)

    assert {:ok, 2} = Staging.prune_feed("nist-nvd2", root: root, keep: 0)
    refute File.exists?(one.run_dir)
    refute File.exists?(two.run_dir)
  end

  test "ensure_budget fails when the staging tree is over the cap", %{root: root} do
    {:ok, paths} = Staging.prepare_run("nist-nvd2", "fat", root)
    File.write!(Path.join(paths.extracted_dir, "blob"), :binary.copy(<<0>>, 4096))

    assert {:error, {:staging_over_budget, used}} =
             Staging.ensure_budget(root: root, max_bytes: 1024, min_free_bytes: 0)

    assert used > 1024
  end

  test "reap_orphans prunes extra nist-nvd2 dirs even when they are fresh", %{root: root} do
    {:ok, older} = Staging.prepare_run("nist-nvd2", "older", root)
    {:ok, newer} = Staging.prepare_run("nist-nvd2", "newer", root)
    File.touch!(older.run_dir, System.system_time(:second) - 10)

    assert {:ok, reaped} = Staging.reap_orphans(root: root, nist_keep: 1, max_age_seconds: 86_400)
    assert reaped >= 1
    refute File.exists?(older.run_dir)
    assert File.exists?(newer.run_dir)
  end

  test "reap_orphans never age-reaps the executing Ubuntu run it was told to keep", %{root: root} do
    {:ok, executing} = Staging.prepare_run("ubuntu-osv-vex", "executing", root)
    now = System.system_time(:second)
    File.touch!(executing.run_dir, now - 3 * 60 * 60)

    assert {:ok, 0} =
             Staging.reap_orphans(
               root: root,
               now: now,
               max_age_seconds: 2 * 60 * 60,
               ubuntu_keep: 1
             )

    assert File.exists?(executing.run_dir)
  end
end
