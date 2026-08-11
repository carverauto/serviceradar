defmodule ServiceRadar.Repo.Migrations.RepairOrphanedPlatformGraph do
  @moduledoc """
  Repairs an AGE `platform_graph` whose catalog entry is gone but whose schema survives.

  `20260204090000_use_platform_age_graph` creates the graph and raises if it is missing,
  so a clean install is already protected. This migration covers what happens *after*
  install: if the AGE extension is ever dropped and recreated -- a CNPG restore from
  backup, a PostgreSQL major upgrade, an image change -- then `ag_catalog.ag_graph` is
  reset while the `platform_graph` schema and its `_ag_label_vertex` / `_ag_label_edge`
  tables remain behind.

  In that state every Cypher query fails with

      ERROR 3F000 (invalid_schema_name): graph "platform_graph" does not exist

  which takes down the entire core coordinator child tree in a restart loop, while every
  pod continues to report Running and Ready and telemetry silently stops being consumed.

  The earlier migration cannot fix it: `ag_catalog.create_graph` raises `duplicate_schema`,
  which it deliberately converts into

      Schema platform_graph already exists; cannot create AGE graph.

  leaving an operator with no documented way forward. This migration performs that repair
  when it is provably safe (the orphaned schema holds no graph data) and otherwise fails
  with the exact command to run, rather than a dead end.

  Idempotent: a healthy install is a no-op.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      graph_name  text := 'platform_graph';
      registered  boolean;
      schema_here boolean;
      row_count   bigint;
      app_role    text := current_user;
    BEGIN
      BEGIN
        EXECUTE 'LOAD ''age''';
      EXCEPTION
        WHEN insufficient_privilege THEN
          IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age') THEN
            RAISE;
          END IF;
      END;

      PERFORM set_config('search_path', 'ag_catalog,platform,"$user",public', true);

      SELECT EXISTS(SELECT 1 FROM ag_catalog.ag_graph WHERE name = graph_name) INTO registered;
      SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = graph_name) INTO schema_here;

      -- Healthy, or a graph that simply does not exist yet: nothing to repair here.
      -- (Creation stays the responsibility of 20260204090000.)
      IF registered THEN
        RETURN;
      END IF;

      IF NOT schema_here THEN
        PERFORM ag_catalog.create_graph(graph_name);
        RAISE NOTICE 'Created missing AGE graph %', graph_name;
        RETURN;
      END IF;

      -- Orphaned: schema present, catalog entry gone. Only drop it when it holds no
      -- graph data, so this can never silently discard a populated topology graph.
      --
      -- Counted for real, not read from pg_class.reltuples: on PostgreSQL 14+ that
      -- column is -1 for a table that has never been analyzed, so a populated graph
      -- restored from a dump would sum to a negative number, read as "empty", and get
      -- dropped. This must be exact.
      row_count := 0;

      DECLARE
        tbl record;
        n   bigint;
      BEGIN
        FOR tbl IN
          SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
          WHERE ns.nspname = graph_name AND c.relkind = 'r'
        LOOP
          EXECUTE format('SELECT count(*) FROM %I.%I', graph_name, tbl.relname) INTO n;
          row_count := row_count + n;
        END LOOP;
      END;

      IF row_count > 0 THEN
        RAISE EXCEPTION
          'AGE graph "%" is unregistered but its schema holds ~% rows. Refusing to drop it. '
          'Inspect the schema, then once you are satisfied the data is expendable run: '
          'DROP SCHEMA % CASCADE; and re-run migrations.',
          graph_name, row_count, graph_name;
      END IF;

      EXECUTE format('DROP SCHEMA %I CASCADE', graph_name);
      PERFORM ag_catalog.create_graph(graph_name);

      RAISE NOTICE 'Repaired orphaned AGE graph % (empty schema dropped and recreated)', graph_name;

      IF NOT EXISTS(SELECT 1 FROM ag_catalog.ag_graph WHERE name = graph_name) THEN
        RAISE EXCEPTION 'AGE graph "%" still missing after repair', graph_name;
      END IF;

      -- create_graph leaves the schema owned by whoever ran it. The application role
      -- must own it, or every Cypher query fails with
      --   ERROR 42501: permission denied for schema platform_graph
      -- which looks nothing like the problem it actually is.
      EXECUTE format('ALTER SCHEMA %I OWNER TO %I', graph_name, app_role);
    END
    $$;
    """)
  end

  def down do
    # Nothing to undo: this migration only repairs an already-broken state.
    :ok
  end
end
