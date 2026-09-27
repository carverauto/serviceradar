defmodule ServiceRadar.Repo.AshSchemaMigrationsSyncDbTest do
  @moduledoc """
  `mix serviceradar.db.migrate` must leave both migration ledgers complete, whichever
  application's config it runs under.

  One schema has two ledgers. Core leaves the shared repo's `:migration_source` unset, so its
  migrator reads and writes `platform.schema_migrations`. web-ng sets it to
  `"ash_schema_migrations"`: its `RequireMigrations` plug answers 503 while any migration on disk
  is `:down` against that ledger, and a migrator run under web-ng's config writes only that one.

  So a ledger falls behind in either direction. When web-ng's does, every web-ng route serves
  503. When core's does, core's migrator treats migrations that were applied as pending and runs
  them again. These tests start from each lagging shape and run the task under each config.

  Every test runs inside its rollback-only sandbox, so the lane database's own ledgers and repo
  config are restored afterwards.
  """
  use ServiceRadar.DataCase, async: false

  alias Mix.Tasks.Serviceradar.Db.Migrate, as: MigrateTask
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.SchemaBootstrap

  @moduletag :integration

  @core_ledger "platform.schema_migrations"
  @ash_ledger "platform.ash_schema_migrations"

  # How many of the newest applied migrations a lagging ledger is missing. The newest, because
  # a run under the other config applied the newest ones; kept small because, without the fix,
  # the migrator runs exactly these again.
  @lag 2

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(original_shell) end)

    :ok
  end

  test "the task records every applied version in web-ng's ledger, and re-running adds none" do
    assert on_disk_versions() != []

    # Never synced: the ledger web-ng reads does not exist yet.
    Repo.query!("DROP TABLE IF EXISTS #{@ash_ledger}")

    assert :ok = MigrateTask.run([])

    assert_ledgers_complete!()
    first = shell_lines()
    assert "applied 0 migration(s)" in first
    assert Enum.any?(first, &(&1 =~ ~r/ [1-9][0-9]* in platform\.ash_schema_migrations$/))

    assert :ok = MigrateTask.run([])

    assert_ledgers_complete!()

    assert Enum.filter(shell_lines(), &String.starts_with?(&1, "ledger sync")) == [
             "ledger sync before migrating: recorded 0 version(s) in #{@core_ledger}, " <>
               "0 in #{@ash_ledger}",
             "ledger sync after migrating: recorded 0 version(s) in #{@core_ledger}, " <>
               "0 in #{@ash_ledger}"
           ]
  end

  test "the no-baseline path syncs too" do
    lag_ledger!(@ash_ledger)

    assert :ok = MigrateTask.run(["--no-baseline"])

    assert_ledgers_complete!()
  end

  test "under core's config, versions only web-ng's ledger records are not applied again" do
    # The shape a migrator run under web-ng's config leaves: it recorded the newest migrations
    # in the ash ledger alone.
    lag_ledger!(@core_ledger)

    assert :ok = MigrateTask.run([])

    assert_received {:mix_shell, :info, ["applied 0 migration(s)"]}
    assert_ledgers_complete!()
  end

  test "under web-ng's config, the task leaves core's ledger complete" do
    use_web_ng_migration_source!()

    # web-ng's migrator never writes core's ledger, so a database it alone migrated has none.
    # Seed the ash ledger explicitly rather than relying on it already being complete: the
    # shared fixture template only ever guarantees the core ledger matches disk.
    seed_ledger!(@ash_ledger)
    Repo.query!("DROP TABLE IF EXISTS #{@core_ledger}")

    assert :ok = MigrateTask.run([])

    assert_received {:mix_shell, :info, ["applied 0 migration(s)"]}
    assert_ledgers_complete!()
  end

  test "under web-ng's config, versions only core's ledger records are not applied again" do
    use_web_ng_migration_source!()
    lag_ledger!(@ash_ledger)

    assert :ok = MigrateTask.run([])

    assert_received {:mix_shell, :info, ["applied 0 migration(s)"]}
    assert_ledgers_complete!()
  end

  test "the sync fills whichever ledger lags and is idempotent" do
    lag_ledger!(@ash_ledger)

    assert SchemaBootstrap.sync_migration_ledgers!(Repo) ==
             %{schema_migrations: 0, ash_schema_migrations: @lag}

    assert_ledgers_complete!()

    lag_ledger!(@core_ledger)

    assert SchemaBootstrap.sync_migration_ledgers!(Repo) ==
             %{schema_migrations: @lag, ash_schema_migrations: 0}

    assert_ledgers_complete!()

    assert SchemaBootstrap.sync_migration_ledgers!(Repo) ==
             %{schema_migrations: 0, ash_schema_migrations: 0}
  end

  # Everything the task has told the shell since the last call, in order.
  defp shell_lines(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> shell_lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Boots the task the way web-ng configures the shared repo. `Ecto.Migrator` reads
  # `:migration_source` from `repo.config/0`, which reads the application env on every call.
  defp use_web_ng_migration_source! do
    original = Application.fetch_env!(:serviceradar_core, Repo)

    Application.put_env(
      :serviceradar_core,
      Repo,
      Keyword.put(original, :migration_source, "ash_schema_migrations")
    )

    on_exit(fn -> Application.put_env(:serviceradar_core, Repo, original) end)
  end

  # Brings both ledgers up to the migrations on disk, then removes the newest @lag from `ledger`
  # alone -- the shape a database has when the migrator ran under the other config.
  #
  # Recording every migration on disk is true here: the lane database was cloned only after
  # //rust/integration-db checked its schema matches this checkout exactly. Plain SQL rather
  # than the sync under test, so the setup cannot share a bug with what it sets up.
  defp lag_ledger!(ledger) do
    for table <- [@core_ledger, @ash_ledger], do: seed_ledger!(table)

    assert_ledgers_complete!()

    lagging = Enum.take(on_disk_versions(), -@lag)
    Repo.query!("DELETE FROM #{ledger} WHERE version = ANY($1::bigint[])", [lagging])

    assert unrecorded(ledger) == lagging
  end

  # Creates `ledger` if missing and records every migration on disk as applied, regardless of
  # what the shared fixture template already put there.
  defp seed_ledger!(ledger) do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{ledger} (
      version bigint NOT NULL PRIMARY KEY,
      inserted_at timestamp(0) without time zone
    )
    """)

    Repo.query!(
      """
      INSERT INTO #{ledger} (version, inserted_at)
      SELECT unnest($1::bigint[]), now()
      ON CONFLICT (version) DO NOTHING
      """,
      [on_disk_versions()]
    )
  end

  defp assert_ledgers_complete! do
    assert unrecorded(@core_ledger) == []
    assert unrecorded(@ash_ledger) == []
  end

  # Migrations on disk the ledger does not record: what a migrator reading it treats as pending,
  # and what web-ng's gate refuses to serve while any remain.
  defp unrecorded(ledger) do
    %{rows: rows} = Repo.query!("SELECT version FROM #{ledger}")
    recorded = MapSet.new(rows, fn [version] -> version end)
    Enum.reject(on_disk_versions(), &MapSet.member?(recorded, &1))
  end

  defp on_disk_versions do
    :serviceradar_core
    |> Application.app_dir("priv/repo/migrations/*.exs")
    |> Path.wildcard()
    |> Enum.map(&SchemaBootstrap.migration_version_from_file/1)
    |> Enum.sort()
  end
end
