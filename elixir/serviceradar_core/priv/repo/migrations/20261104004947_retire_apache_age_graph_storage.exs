defmodule ServiceRadar.Repo.Migrations.RetireApacheAgeGraphStorage do
  @moduledoc """
  Removes the Apache AGE graph storage now that Dgraph is the only topology graph.

  Nothing reads or writes AGE any more: SRQL, web-ng, the correlation hydrator and every
  topology writer moved to Dgraph (`openspec/changes/replace-age-topology-with-dgraph`, tasks
  14.1-14.4). This migration removes what those consumers left behind, in this order:

    1. `public.age_device_neighborhood(text, boolean, boolean)`, the PL/pgSQL wrapper the
       retired `in:device_graph` SQL path called. Its signature uses only `text`, `boolean`
       and `jsonb`, so it is dropped by name whether or not AGE is installed.
    2. `platform.runtime_topology_links`, the relational projection fed by the retired
       `RuntimeTopologyProjection`. `platform.runtime_topology_projection_meta` stays: the
       Dgraph canonical rebuild still records its freshness there.
    3. Every graph registered in `ag_catalog.ag_graph`, read from the catalog rather than
       assumed. On an upgraded installation that is `platform_graph`, plus the legacy
       `serviceradar` and `serviceradar_topology` graphs where they survived.
    4. Graph storage AGE has no record of (see "Unregistered graph schemas").
    5. The `age` extension, with `RESTRICT`, then its now-empty `ag_catalog` schema.

  A database without the `age` extension skips steps 3-5. Every statement is guarded, so a
  second run is a no-op.

  ## The `drop_graph` cascade

  `ag_catalog.drop_graph(name, true)` is the one cascading drop here, and it is deliberate.
  AGE stores a graph as a schema named after it: `_ag_label_vertex` and `_ag_label_edge`, a
  table per label that inherits from one of them, the sequences behind their ids, and the
  indexes on them (the property indexes from `20260622210000` included). `drop_graph` drops that
  schema with `CASCADE` and deletes the graph's rows from `ag_catalog.ag_graph` and
  `ag_catalog.ag_label`. `cascade => false` refuses whenever a label table exists, which on an
  installation that ever held topology is always.

  The cascade is bounded by construction. Before any graph is dropped, the migration reads
  `pg_depend` for every object, in any schema other than the graph schemas themselves, that
  depends on a relation, type, function or the namespace of a graph schema. If one exists -- a
  view over a label table, a foreign key into one, a function returning a label row type -- the
  migration raises and names it, and nothing is dropped. So `drop_graph` only ever removes the
  graph schemas' own contents: AGE label tables, their sequences, indexes, constraints and
  defaults, and the rows AGE keeps about them. Topology evidence lives in relational tables
  (`mapper_topology_links` and the canonical edge tables), which never depend on graph objects
  and are untouched.

  ## Unregistered graph schemas

  A database built from the schema baseline holds the graph schemas without their
  `ag_catalog.ag_graph` rows: the baseline is a `pg_dump --schema-only`, which re-creates the
  label tables as plain DDL and never calls `create_graph()` (see "Why the schema baseline cannot
  be replayed" in `docs/agent-runbooks.md`). `drop_graph` cannot reach those, and their
  `graphid`/`agtype` columns would block `DROP EXTENSION age ... RESTRICT`.

  They are found by their column types: a table outside `ag_catalog` with a column of a type the
  `age` extension owns. A schema qualifies only if EVERY table in it consists solely of such
  columns, which is the shape of AGE label storage and of nothing this application creates. A
  schema that mixes in any other table makes the migration raise rather than guess. A qualifying
  schema is removed without `CASCADE`: one `DROP TABLE` naming all of its tables (parents and
  inheriting children together), one `DROP SEQUENCE` for the free-standing sequences, then
  `DROP SCHEMA`, which fails if anything else remains in it. The `pg_depend` check above covers
  these schemas too.

  ## Privileges

  Deployments run this as the CNPG superuser (the Helm `core-migrations` job and the Compose
  `core-elx-migrations` service both connect with the superuser secret), which owns the
  extension. A role
  that neither is a superuser nor owns the extension cannot drop it; that is the CI schema
  generation, which `//rust/integration-db` creates the extension in as its admin role and then
  migrates as the ordinary application role. There the graphs and their storage are still
  removed, and the empty extension is left in place with a warning instead of failing the
  migration.

  The baseline (`priv/repo/baseline/`) still contains the AGE objects and the CNPG image still
  ships AGE; regenerating the one and removing the other is tracked separately
  (carverauto/serviceradar-control#192). A database built from that baseline converges here.
  """

  use Ecto.Migration

  def up do
    execute("DROP FUNCTION IF EXISTS public.age_device_neighborhood(text, boolean, boolean)")
    execute("DROP TABLE IF EXISTS platform.runtime_topology_links")
    execute(retire_age_sql())
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "Apache AGE graph storage is not restored: Dgraph is the only topology graph. " <>
          "Rebuild Dgraph topology from the relational evidence instead."
  end

  defp retire_age_sql do
    """
    DO $retire_age$
    DECLARE
      age_extension record;
      graph_namespaces oid[];
      external_dependents text;
      mixed_tables text;
      graph record;
      orphan record;
      table_list text;
      sequence_list text;
    BEGIN
      SELECT e.oid, e.extowner
        INTO age_extension
        FROM pg_extension e
       WHERE e.extname = 'age';

      IF NOT FOUND THEN
        RAISE NOTICE 'Apache AGE is not installed; no graph storage to retire';
        RETURN;
      END IF;

      -- Graph schemas: those AGE registered, and those holding tables made of AGE types.
      CREATE TEMP TABLE retire_age_graph_schemas (
        nsp oid PRIMARY KEY,
        name text NOT NULL,
        registered boolean NOT NULL
      ) ON COMMIT DROP;

      INSERT INTO retire_age_graph_schemas (nsp, name, registered)
      SELECT g.namespace::oid, g.name::text, true
        FROM ag_catalog.ag_graph g;

      INSERT INTO retire_age_graph_schemas (nsp, name, registered)
      SELECT DISTINCT n.oid, n.nspname::text, false
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_depend member
          ON member.classid = 'pg_type'::regclass
         AND member.objid = a.atttypid
         AND member.refclassid = 'pg_extension'::regclass
         AND member.refobjid = age_extension.oid
         AND member.deptype = 'e'
       WHERE c.relkind IN ('r', 'p')
         AND a.attnum > 0
         AND NOT a.attisdropped
         AND n.nspname <> 'ag_catalog'
      ON CONFLICT (nsp) DO NOTHING;

      SELECT array_agg(s.nsp) INTO graph_namespaces FROM retire_age_graph_schemas s;

      IF graph_namespaces IS NULL THEN
        graph_namespaces := ARRAY[]::oid[];
      END IF;

      -- An unregistered schema qualifies only if every table in it is made of AGE types.
      SELECT string_agg(DISTINCT format('%I.%I', n.nspname, c.relname), ', ')
        INTO mixed_tables
        FROM retire_age_graph_schemas s
        JOIN pg_namespace n ON n.oid = s.nsp
        JOIN pg_class c ON c.relnamespace = s.nsp AND c.relkind IN ('r', 'p')
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
       WHERE NOT s.registered
         AND NOT EXISTS (
           SELECT 1
             FROM pg_depend member
            WHERE member.classid = 'pg_type'::regclass
              AND member.objid = a.atttypid
              AND member.refclassid = 'pg_extension'::regclass
              AND member.refobjid = age_extension.oid
              AND member.deptype = 'e'
         );

      IF mixed_tables IS NOT NULL THEN
        RAISE EXCEPTION
          'refusing to retire Apache AGE: unregistered schemas mix AGE label storage with other tables (%)',
          mixed_tables;
      END IF;

      -- Nothing outside the graph schemas may depend on anything inside them. This is what
      -- bounds drop_graph's cascade to AGE's own storage.
      SELECT string_agg(
               DISTINCT format(
                 '%s depends on %s',
                 pg_describe_object(d.classid, d.objid, d.objsubid),
                 pg_describe_object(d.refclassid, d.refobjid, d.refobjsubid)
               ),
               '; '
             )
        INTO external_dependents
        FROM pg_depend d
        JOIN LATERAL (
          SELECT c.relnamespace AS nsp FROM pg_class c
           WHERE d.refclassid = 'pg_class'::regclass AND c.oid = d.refobjid
          UNION ALL
          SELECT t.typnamespace FROM pg_type t
           WHERE d.refclassid = 'pg_type'::regclass AND t.oid = d.refobjid
          UNION ALL
          SELECT p.pronamespace FROM pg_proc p
           WHERE d.refclassid = 'pg_proc'::regclass AND p.oid = d.refobjid
          UNION ALL
          SELECT d.refobjid WHERE d.refclassid = 'pg_namespace'::regclass
        ) referenced ON referenced.nsp = ANY (graph_namespaces)
        -- The dependent's own schema. Defaults, triggers, rules and policies belong to no
        -- schema, so they are placed in the schema of the relation they hang off.
        LEFT JOIN LATERAL (
          SELECT c.relnamespace AS nsp FROM pg_class c
           WHERE d.classid = 'pg_class'::regclass AND c.oid = d.objid
          UNION ALL
          SELECT t.typnamespace FROM pg_type t
           WHERE d.classid = 'pg_type'::regclass AND t.oid = d.objid
          UNION ALL
          SELECT p.pronamespace FROM pg_proc p
           WHERE d.classid = 'pg_proc'::regclass AND p.oid = d.objid
          UNION ALL
          SELECT k.connamespace FROM pg_constraint k
           WHERE d.classid = 'pg_constraint'::regclass AND k.oid = d.objid
          UNION ALL
          SELECT c.relnamespace FROM pg_attrdef ad JOIN pg_class c ON c.oid = ad.adrelid
           WHERE d.classid = 'pg_attrdef'::regclass AND ad.oid = d.objid
          UNION ALL
          SELECT c.relnamespace FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
           WHERE d.classid = 'pg_trigger'::regclass AND tg.oid = d.objid
          UNION ALL
          SELECT c.relnamespace FROM pg_rewrite rw JOIN pg_class c ON c.oid = rw.ev_class
           WHERE d.classid = 'pg_rewrite'::regclass AND rw.oid = d.objid
          UNION ALL
          SELECT c.relnamespace FROM pg_policy pol JOIN pg_class c ON c.oid = pol.polrelid
           WHERE d.classid = 'pg_policy'::regclass AND pol.oid = d.objid
          -- Default privileges and extended statistics on a graph schema are its own auto dependents.
          UNION ALL
          SELECT da.defaclnamespace FROM pg_default_acl da
           WHERE d.classid = 'pg_default_acl'::regclass AND da.oid = d.objid
          UNION ALL
          SELECT se.stxnamespace FROM pg_statistic_ext se
           WHERE d.classid = 'pg_statistic_ext'::regclass AND se.oid = d.objid
        ) dependent ON true
       WHERE d.deptype NOT IN ('i', 'e')
         -- An object of any other kind, or in any other schema, is outside the graphs.
         AND (dependent.nsp IS NULL OR NOT (dependent.nsp = ANY (graph_namespaces)));

      IF external_dependents IS NOT NULL THEN
        RAISE EXCEPTION
          'refusing to retire Apache AGE: objects outside the graph schemas depend on them (%)',
          external_dependents;
      END IF;

      FOR graph IN
        SELECT s.name FROM retire_age_graph_schemas s WHERE s.registered ORDER BY s.name
      LOOP
        RAISE NOTICE 'Dropping Apache AGE graph %', graph.name;
        PERFORM ag_catalog.drop_graph(graph.name::name, true);
      END LOOP;

      FOR orphan IN
        SELECT s.nsp, s.name FROM retire_age_graph_schemas s WHERE NOT s.registered ORDER BY s.name
      LOOP
        RAISE NOTICE 'Dropping unregistered Apache AGE graph schema %', orphan.name;

        SELECT string_agg(format('%I.%I', orphan.name, c.relname), ', ' ORDER BY c.relname)
          INTO table_list
          FROM pg_class c
         WHERE c.relnamespace = orphan.nsp AND c.relkind IN ('r', 'p');

        IF table_list IS NOT NULL THEN
          EXECUTE 'DROP TABLE ' || table_list;
        END IF;

        SELECT string_agg(format('%I.%I', orphan.name, c.relname), ', ' ORDER BY c.relname)
          INTO sequence_list
          FROM pg_class c
         WHERE c.relnamespace = orphan.nsp AND c.relkind = 'S';

        IF sequence_list IS NOT NULL THEN
          EXECUTE 'DROP SEQUENCE ' || sequence_list;
        END IF;

        EXECUTE format('DROP SCHEMA %I', orphan.name);
      END LOOP;

      IF NOT pg_has_role(current_user, age_extension.extowner, 'USAGE') THEN
        RAISE WARNING
          'Apache AGE graphs are retired, but role % cannot drop the age extension (owned by %); run DROP EXTENSION age as its owner',
          current_user, age_extension.extowner::regrole;
        RETURN;
      END IF;

      DROP EXTENSION age RESTRICT;

      IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'ag_catalog') THEN
        DROP SCHEMA ag_catalog RESTRICT;
      END IF;
    END
    $retire_age$;
    """
  end
end
