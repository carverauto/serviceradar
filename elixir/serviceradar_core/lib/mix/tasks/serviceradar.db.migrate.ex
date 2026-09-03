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

        applied = Ecto.Migrator.run(repo, :up, all: true)
        Mix.shell().info("applied #{length(applied)} migration(s)")
      end)

    :ok
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
        repair platform.schema_migrations before retrying.

        Details: #{inspect(details)}
        """)
    end
  end
end
