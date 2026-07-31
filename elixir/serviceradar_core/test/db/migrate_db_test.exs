defmodule ServiceRadar.DB.MigrateTest do
  @moduledoc """
  Applies the Ecto migrations to the shared template database.

  This is what `mix ash.migrate` used to do from the CI job, and it is the ONLY part of the
  database lifecycle that has to run on the BEAM: the 368 migrations are
  `use Ecto.Migration` modules, so only `Ecto.Migrator` can execute them. Creating databases,
  installing extensions, the AGE graphs and the teardown all moved to
  //rust/integration-db, which starts in 0.1s against this target's ~30-45s.

  Which database it targets is decided by `test/db/template_env.exs`, loaded ahead of the
  config loader: the template, not a per-run database. Per-run databases are physical copies
  of it, so this runs once per migration added rather than once per CI run.

  `Ecto.Migrator` applies only what `schema_migrations` says is pending, so re-running this
  against a current template is a no-op rather than an error. That is also the predicate
  //rust/integration-db:prepare_template evaluates to decide whether to invoke this target
  at all.

  Ordering is the workflow's job -- Bazel gives no guarantee between targets or between
  tests within one -- and it runs after //rust/integration-db:prepare_template and before
  //rust/integration-db:provision_db.

  Tagged `external`, which disables Bazel's test caching. Without it a rerun would report a
  cache hit and apply no migrations at all.
  """
  use ExUnit.Case, async: false

  @moduletag :migrate_db
  # Bazel already bounds this target's wall clock (size = "enormous"). A second, shorter
  # ExUnit budget on top of it is not a safety net -- it kills the migrator mid-run and
  # leaves a half-applied schema that the next attempt trips over ("relation ... already
  # exists"). One owner for the deadline, and it is Bazel.
  @moduletag timeout: :infinity

  alias ServiceRadar.Repo

  test "migrations apply cleanly to the integration database" do
    # with_repo starts the repo and its dependencies, runs the function, and stops it
    # again -- the same thing `mix ecto.migrate` does, without needing Mix.
    result =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        Ecto.Migrator.run(repo, :up, all: true)
      end)

    case result do
      {:ok, applied, _started_apps} ->
        IO.puts("applied #{length(applied)} migration(s)")

      {:error, reason} ->
        flunk("""
        migrations failed: #{inspect(reason)}

        Repo config in effect:
        #{inspect(Application.get_env(:serviceradar_core, Repo) |> Keyword.drop([:password]))}
        """)
    end
  end
end
