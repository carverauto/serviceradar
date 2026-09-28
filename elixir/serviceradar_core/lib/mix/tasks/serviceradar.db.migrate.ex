defmodule Mix.Tasks.Serviceradar.Db.Migrate do
  @shortdoc "Bring a database up to date, baselining it when it is empty"

  @moduledoc """
  Brings a database up to date the way service startup does.

  An empty database is created from the committed schema baseline and the migrations that
  baseline contains are recorded as applied, rather than replayed. A database with migration
  history runs only what is pending.

      mix serviceradar.db.migrate
      mix serviceradar.db.migrate --no-baseline

  Prefer this over `mix ecto.migrate` for a fresh database. `ecto.migrate` replays every
  migration on disk, which is slow and, against a remote instance, has historically failed
  outright -- see issue #4151. `ServiceRadar.Cluster.StartupMigrations` has always baselined
  instead; this task gives the same behaviour to a developer at a shell.

  Like startup, it keeps `platform.schema_migrations` and `platform.ash_schema_migrations` in
  step (`ServiceRadar.Repo.SchemaBootstrap.sync_migration_ledgers!/1`), both before the migrator
  and after it. Which of the two the migrator writes depends on the config it runs under: core's
  leaves the repo's `:migration_source` unset, web-ng's sets it to `ash_schema_migrations`.
  Without the copy before, a run under one config replays what a run under the other applied;
  without the copy after, web-ng's migrations gate answers every route with 503, or core's
  startup finds migrations pending, against a database this task brought fully up to date.

  Options:

    * `--no-baseline` - never apply the baseline; replay migrations even on an empty database.
      This is `mix ecto.migrate`'s behaviour, kept for reproducing a full replay deliberately.
  """

  use Mix.Task

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.SchemaBootstrap

  @switches [baseline: :boolean]

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    baseline? = Keyword.get(opts, :baseline, true)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        migrations_path = Application.app_dir(:serviceradar_core, "priv/repo/migrations")

        if baseline? do
          bootstrap!(repo, migrations_path)
        else
          Mix.shell().info("--no-baseline: replaying every migration on disk")
        end

        # So the migrator computes pending from every version either ledger records, not only
        # from the one this config names.
        report_sync("before migrating", SchemaBootstrap.sync_migration_ledgers!(repo))

        applied = Ecto.Migrator.run(repo, :up, all: true)
        Mix.shell().info("applied #{length(applied)} migration(s)")

        # Runs on every path, the baseline one included: the baseline records its versions
        # as applied without running them, so they reach the other ledger only through here.
        report_sync("after migrating", SchemaBootstrap.sync_migration_ledgers!(repo))
      end)

    :ok
  end

  defp report_sync(stage, %{schema_migrations: core, ash_schema_migrations: ash}) do
    Mix.shell().info(
      "ledger sync #{stage}: recorded #{core} version(s) in platform.schema_migrations, " <>
        "#{ash} in platform.ash_schema_migrations"
    )
  end

  defp bootstrap!(repo, migrations_path) do
    case SchemaBootstrap.classify(repo) do
      :empty ->
        Mix.shell().info("empty database; applying schema baseline")
        SchemaBootstrap.apply_baseline!(repo, migrations_path)

      :migrated ->
        Mix.shell().info("existing migration history; applying pending migrations only")

      {:ambiguous, details} ->
        # Fail closed rather than baseline over a real schema. Same rule as startup.
        Mix.raise("""
        ambiguous database state; refusing to bootstrap automatically.

        Platform objects exist without coherent migration history. Restore from backup or
        repair the repository's configured migration ledger before retrying.

        Details: #{inspect(details)}
        """)
    end
  end
end
