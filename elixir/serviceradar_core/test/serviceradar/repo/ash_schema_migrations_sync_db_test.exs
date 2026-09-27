defmodule ServiceRadar.Repo.AshSchemaMigrationsSyncDbTest do
  @moduledoc """
  `mix serviceradar.db.migrate` must leave web-ng's migration ledger complete.

  web-ng configures the shared repo with `migration_source: "ash_schema_migrations"`, and its
  `RequireMigrations` plug answers 503 while any migration on disk is `:down` against that
  ledger. Core migrates through `platform.schema_migrations`, so every path that brings a
  database up to date has to copy the versions across. Startup always did; the Mix task did not,
  and a database it had fully migrated served 503 on every web-ng route.

  Each test starts from the lagging ledger a database migrated by the old task had, inside the
  test's rollback-only sandbox, so the lane database's own ledger is restored afterwards.
  """
  use ServiceRadar.DataCase, async: false

  alias Mix.Tasks.Serviceradar.Db.Migrate, as: MigrateTask
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.SchemaBootstrap

  @moduletag :integration

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(original_shell) end)

    :ok
  end

  test "the task records every applied version in web-ng's ledger, and re-running adds none" do
    assert core_versions() != []

    # Never synced: the ledger web-ng reads does not exist yet.
    Repo.query!("DROP TABLE IF EXISTS platform.ash_schema_migrations")

    assert :ok = MigrateTask.run([])

    assert missing_from_ash_ledger() == []
    assert pending_for_web_ng_gate() == []
    assert_received {:mix_shell, :info, ["recorded " <> recorded]}
    refute recorded =~ ~r/^0 /

    assert :ok = MigrateTask.run([])

    assert missing_from_ash_ledger() == []
    assert_received {:mix_shell, :info, ["recorded 0 version(s)" <> _]}
  end

  test "the no-baseline path syncs too" do
    lag_ash_ledger!()

    assert :ok = MigrateTask.run(["--no-baseline"])

    assert missing_from_ash_ledger() == []
    assert pending_for_web_ng_gate() == []
  end

  test "the sync fills a lagging ledger and is idempotent" do
    lagged = lag_ash_ledger!()

    assert SchemaBootstrap.sync_ash_schema_migrations!(Repo) == lagged
    assert missing_from_ash_ledger() == []

    assert SchemaBootstrap.sync_ash_schema_migrations!(Repo) == 0
    assert missing_from_ash_ledger() == []
  end

  # Rebuilds web-ng's ledger holding only the older half of core's versions: the shape a
  # database has when core applied migrations the Mix task never copied across. Returns how
  # many versions are missing from it.
  defp lag_ash_ledger! do
    {kept, lagging} = Enum.split(core_versions(), div(length(core_versions()), 2))

    Repo.query!("DROP TABLE IF EXISTS platform.ash_schema_migrations")

    Repo.query!("""
    CREATE TABLE platform.ash_schema_migrations (
      version bigint NOT NULL PRIMARY KEY,
      inserted_at timestamp(0) without time zone
    )
    """)

    Repo.query!(
      """
      INSERT INTO platform.ash_schema_migrations (version, inserted_at)
      SELECT unnest($1::bigint[]), now()
      """,
      [kept]
    )

    assert lagging != []
    assert missing_from_ash_ledger() == lagging
    length(lagging)
  end

  defp core_versions do
    %{rows: rows} =
      Repo.query!("SELECT version FROM platform.schema_migrations ORDER BY version")

    Enum.map(rows, fn [version] -> version end)
  end

  defp ash_versions do
    %{rows: rows} = Repo.query!("SELECT version FROM platform.ash_schema_migrations")
    MapSet.new(rows, fn [version] -> version end)
  end

  defp missing_from_ash_ledger do
    ash = ash_versions()
    Enum.reject(core_versions(), &MapSet.member?(ash, &1))
  end

  # What web-ng's RequireMigrations gate treats as pending: a migration on disk whose version
  # is absent from the ledger it reads.
  defp pending_for_web_ng_gate do
    ash = ash_versions()

    :serviceradar_core
    |> Application.app_dir("priv/repo/migrations/*.exs")
    |> Path.wildcard()
    |> Enum.map(&SchemaBootstrap.migration_version_from_file/1)
    |> Enum.reject(&MapSet.member?(ash, &1))
  end
end
