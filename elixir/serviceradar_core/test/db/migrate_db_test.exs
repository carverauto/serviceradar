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
        # Classify first, and only to decide what to SAY and what to refuse -- the migrator
        # below applies whatever is pending either way, so a database with history behaves
        # exactly as before. What changed is the `:empty` arm; see the comment on it.
        case SchemaBootstrap.classify(repo) do
          :empty ->
            # REPLAY, never the baseline. The committed baseline is a `pg_dump --schema-only`,
            # and rust/integration-db/src/template.rs says why that cannot rebuild this schema:
            # TimescaleDB keeps hypertables, continuous aggregates and retention policies in
            # `_timescaledb_catalog`, and AGE keeps graphs in `ag_catalog` plus a schema per
            # graph, so a dump does not round-trip. The dump proves it -- 177 references into
            # `_timescaledb_internal` (`_compressed_hypertable_45`, `_direct_view_23`, names
            # carrying the SOURCE database's OIDs) and 42 statements reproducing AGE's per-graph
            # storage. Replaying those does not merely need privileges nobody here has; it is
            # wrong, because `create_hypertable()` and `create_graph()` register objects in
            # catalogs that plain DDL never touches. A database built that way holds graph
            # tables `ag_catalog.ag_graph` has no row for.
            #
            # This path had never run: the template was never empty until it was reset on
            # 2026-09-05, and then every run on the fixture -- trunk included -- died in it.
            #
            # The migrations, by contrast, are written FOR a pre-provisioned database:
            # `CREATE SCHEMA IF NOT EXISTS platform`, `CREATE EXTENSION IF NOT EXISTS`, and
            # `create_graph` inside a duplicate_object/duplicate_schema handler. That is exactly
            # the database //rust/integration-db:install_extensions hands this target.
            #
            # It costs one slow run per template rebuild, which is rare and is trunk's to pay:
            # afterwards the template has history, `classify/1` returns `:migrated`, and every
            # later run applies only what is pending. `Mix.Tasks.Serviceradar.Db.Migrate` keeps
            # both behaviours behind `--no-baseline`; this target has only the correct one,
            # deliberately, because a knob here is an invitation to turn the broken path back on.
            IO.puts(
              "empty database; replaying every migration (baseline cannot rebuild this schema)"
            )

          :migrated ->
            IO.puts("existing migration history; applying pending migrations only")

          {:ambiguous, details} ->
            # Fail closed. Migrating over a real schema with no history would corrupt it.
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
