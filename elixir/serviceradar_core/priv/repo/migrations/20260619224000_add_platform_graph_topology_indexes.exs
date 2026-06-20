defmodule ServiceRadar.Repo.Migrations.AddPlatformGraphTopologyIndexes do
  @moduledoc """
  Adds AGE backing-table indexes for the topology runtime graph hot path.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      graph_name text := 'platform_graph';
      graph_exists boolean;
      has_graphid_btree_ops boolean;
      device_table regclass;
      topology_table regclass;
    BEGIN
      BEGIN
        EXECUTE 'LOAD ''age''';
      EXCEPTION
        WHEN insufficient_privilege THEN
          IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age') THEN
            RAISE NOTICE 'Skipping LOAD ''age'' due to insufficient privilege; AGE extension already exists.';
          ELSE
            RAISE;
          END IF;
      END;

      SELECT EXISTS(SELECT 1 FROM ag_catalog.ag_graph WHERE name = graph_name) INTO graph_exists;
      IF NOT graph_exists THEN
        RAISE NOTICE 'AGE graph "%" is missing; skipping topology indexes.', graph_name;
        RETURN;
      END IF;

      SELECT EXISTS(
        SELECT 1
        FROM pg_opclass oc
        JOIN pg_am am ON am.oid = oc.opcmethod
        JOIN pg_type t ON t.oid = oc.opcintype
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE am.amname = 'btree'
          AND n.nspname = 'ag_catalog'
          AND t.typname = 'graphid'
      ) INTO has_graphid_btree_ops;

      IF has_graphid_btree_ops THEN
        BEGIN
          IF to_regclass(format('%I.%I', graph_name, 'Device')) IS NULL THEN
            PERFORM ag_catalog.create_vlabel(graph_name::cstring, 'Device'::cstring);
          END IF;

          IF to_regclass(format('%I.%I', graph_name, 'CANONICAL_TOPOLOGY')) IS NULL THEN
            PERFORM ag_catalog.create_elabel(graph_name::cstring, 'CANONICAL_TOPOLOGY'::cstring);
          END IF;
        EXCEPTION
          WHEN duplicate_table OR duplicate_object THEN
            NULL;
          WHEN others THEN
            RAISE NOTICE 'Could not create missing AGE topology labels; indexes will be added only for existing labels: %', SQLERRM;
        END;
      ELSE
        RAISE NOTICE 'AGE graphid btree operator class is unavailable; not creating missing AGE labels.';
      END IF;

      device_table := to_regclass(format('%I.%I', graph_name, 'Device'));
      topology_table := to_regclass(format('%I.%I', graph_name, 'CANONICAL_TOPOLOGY'));

      IF device_table IS NOT NULL THEN
        EXECUTE format(
          'CREATE INDEX IF NOT EXISTS platform_graph_device_properties_id_idx ON %s (((properties OPERATOR(ag_catalog.->>) %L::text))) WHERE COALESCE(properties OPERATOR(ag_catalog.->>) %L::text, '''') <> ''''',
          device_table,
          'id',
          'id'
        );
      ELSE
        RAISE NOTICE 'AGE Device label table is missing; skipping Device.id property index.';
      END IF;

      IF topology_table IS NOT NULL THEN
        EXECUTE format(
          'CREATE INDEX IF NOT EXISTS platform_graph_canonical_topology_relation_type_idx ON %s (((properties OPERATOR(ag_catalog.->>) %L::text))) WHERE COALESCE(properties OPERATOR(ag_catalog.->>) %L::text, '''') <> ''''',
          topology_table,
          'relation_type',
          'relation_type'
        );

        EXECUTE format(
          'CREATE INDEX IF NOT EXISTS platform_graph_canonical_topology_evidence_class_idx ON %s (((properties OPERATOR(ag_catalog.->>) %L::text))) WHERE COALESCE(properties OPERATOR(ag_catalog.->>) %L::text, '''') <> ''''',
          topology_table,
          'evidence_class',
          'evidence_class'
        );

        EXECUTE format(
          'CREATE INDEX IF NOT EXISTS platform_graph_canonical_topology_observed_at_idx ON %s (((COALESCE(properties OPERATOR(ag_catalog.->>) %L::text, properties OPERATOR(ag_catalog.->>) %L::text))))',
          topology_table,
          'last_observed_at',
          'observed_at'
        );
      ELSE
        RAISE NOTICE 'AGE CANONICAL_TOPOLOGY label table is missing; skipping edge property indexes.';
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    DECLARE
      graph_name text := 'platform_graph';
    BEGIN
      IF to_regclass(format('%I.%I', graph_name, 'Device')) IS NOT NULL THEN
        EXECUTE format(
          'DROP INDEX IF EXISTS %I.%I',
          graph_name,
          'platform_graph_device_properties_id_idx'
        );
      END IF;

      IF to_regclass(format('%I.%I', graph_name, 'CANONICAL_TOPOLOGY')) IS NOT NULL THEN
        EXECUTE format(
          'DROP INDEX IF EXISTS %I.%I',
          graph_name,
          'platform_graph_canonical_topology_observed_at_idx'
        );
        EXECUTE format(
          'DROP INDEX IF EXISTS %I.%I',
          graph_name,
          'platform_graph_canonical_topology_evidence_class_idx'
        );
        EXECUTE format(
          'DROP INDEX IF EXISTS %I.%I',
          graph_name,
          'platform_graph_canonical_topology_relation_type_idx'
        );
      END IF;
    END
    $$;
    """)
  end
end
