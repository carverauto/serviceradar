defmodule ServiceRadar.DB.MigrateTest do
  @moduledoc """
  Applies the Ecto migrations to whichever database the loaded env preloader named.

  This is what `mix ash.migrate` used to do from the CI job, and it is the ONLY part of the
  database lifecycle that has to run on the BEAM: the 368 migrations are
  `use Ecto.Migration` modules, so only `Ecto.Migrator` can execute them. Creating databases,
  installing extensions, the AGE graphs and the teardown all moved to
  //rust/integration-db, which starts in 0.1s against this target's ~30-45s.

  Which database it targets is decided by the preloader the Bazel target loads ahead of the
  config loader, and there are exactly two:

    * `:migrate_template` loads `test/db/template_env.exs` -> `sr_core_template`, the shared
      cache of trunk's schema. TRUNK ONLY.
    * `:migrate_run` loads `test/db/integration_env.exs` -> `sr_core_test_<run>`, this run's
      own base. Every other lifecycle, including every pull request.

  That split is not cosmetic. BazelCI triggers on `pull_request` only, so while this target
  had one destination, every run that reached it advanced the SHARED template with migrations
  that were not on staging -- and every later run whose checkout lacked them was refused a
  clone. One branch left seven behind and every other pull request went red on a step
  unrelated to its diff.

  `Ecto.Migrator` applies only what `schema_migrations` says is pending, so re-running this
  against a current database is a no-op rather than an error. That is also the predicate
  //rust/integration-db:prepare_template and :provision_base evaluate to decide whether to
  invoke this target at all.

  Ordering is the workflow's job -- Bazel gives no guarantee between targets or between
  tests within one -- and it runs after //rust/integration-db:provision_base (or
  :prepare_template, on trunk) and before //rust/integration-db:provision_db.

  Tagged `external`, which disables Bazel's test caching. Without it a rerun would report a
  cache hit and apply no migrations at all.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.SchemaBootstrap

  @moduletag :migrate_db
  # Bazel already bounds this target's wall clock (size = "enormous"). A second, shorter
  # ExUnit budget on top of it is not a safety net -- it kills the migrator mid-run and
  # leaves a half-applied schema that the next attempt trips over ("relation ... already
  # exists"). One owner for the deadline, and it is Bazel.
  @moduletag timeout: :infinity

  test "migrations apply cleanly to the integration database" do
    # with_repo starts the repo and its dependencies, runs the function, and stops it
    # again -- the same thing `mix ecto.migrate` does, without needing Mix.
    result =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        # Baseline an empty database rather than replaying every migration, which is what
        # service startup has always done. Doing it here too is what keeps the 318 migrations
        # the baseline already contains off this target's critical path -- and off the path of
        # `20260126120000`, whose ledger relocation is issue #4151.
        #
        # `Ecto.Migrator.run/3` below is unchanged and still applies whatever is pending, so a
        # database that already has history behaves exactly as before.
        migrations_path = Application.app_dir(:serviceradar_core, "priv/repo/migrations")

        case SchemaBootstrap.classify(repo) do
          :empty ->
            IO.puts("empty database; applying schema baseline")
            SchemaBootstrap.apply_baseline!(repo, migrations_path)

          :migrated ->
            IO.puts("existing migration history; applying pending migrations only")

          {:ambiguous, details} ->
            # Fail closed. Baselining over a real schema would overwrite it.
            flunk("""
            ambiguous database state; refusing to bootstrap.

            Platform objects exist without coherent migration history.
            Details: #{inspect(details)}
            """)
        end

        Ecto.Migrator.run(repo, :up, all: true)
      end)

    case result do
      {:ok, applied, _started_apps} ->
        IO.puts("applied #{length(applied)} migration(s)")

      {:error, reason} ->
        flunk("""
        migrations failed: #{inspect(reason)}

        Repo config in effect:
        #{:serviceradar_core |> Application.get_env(Repo) |> Keyword.drop([:password, :url]) |> inspect()}
        """)
    end
  end
end
