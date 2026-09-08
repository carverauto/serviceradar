defmodule ServiceRadar.Repo.Migrations.AddVirtualizationV3IdentityScope do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"
  @identity_tables ~w(virtualization_clusters virtualization_hosts virtualization_guests)a

  def up do
    Enum.each(@identity_tables, &add_identity_columns/1)

    create table(:virtualization_identity_aliases, primary_key: false, prefix: @prefix) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :provider, :text, null: false
      add :resource_kind, :text, null: false
      add :legacy_provider_ref, :text, null: false
      add :target_provider_ref, :text
      add :status, :text, null: false, default: "unresolved"
      add :reason, :text
      add :candidate_provider_refs, {:array, :text}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(
             :virtualization_identity_aliases,
             [:provider, :resource_kind, :legacy_provider_ref],
             prefix: @prefix,
             name: :virtualization_identity_aliases_legacy_ref_idx
           )

    create index(:virtualization_identity_aliases, [:target_provider_ref],
             prefix: @prefix,
             name: :virtualization_identity_aliases_target_ref_idx
           )

    create index(:virtualization_identity_aliases, [:status],
             prefix: @prefix,
             name: :virtualization_identity_aliases_status_idx
           )

    create constraint(
             :virtualization_identity_aliases,
             :virtualization_identity_aliases_resource_kind_valid,
             prefix: @prefix,
             check: "resource_kind IN ('cluster', 'host', 'guest')"
           )

    create constraint(
             :virtualization_identity_aliases,
             :virtualization_identity_aliases_status_valid,
             prefix: @prefix,
             check: "status IN ('resolved', 'ambiguous', 'unresolved')"
           )

    create constraint(
             :virtualization_identity_aliases,
             :virtualization_identity_aliases_state_consistent,
             prefix: @prefix,
             check: """
             (status = 'resolved'
               AND target_provider_ref IS NOT NULL
               AND cardinality(candidate_provider_refs) = 1)
             OR (status = 'ambiguous'
               AND target_provider_ref IS NULL
               AND cardinality(candidate_provider_refs) >= 2)
             OR (status = 'unresolved'
               AND target_provider_ref IS NULL
               AND cardinality(candidate_provider_refs) = 0)
             """
           )

    add_identity_constraints_and_indexes()
    backfill_safe_native_components()
    seed_unresolved_legacy_aliases()
    create_identity_guards()
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS virtualization_guest_owner_scope_guard ON #{@prefix}.virtualization_guests"
    )

    Enum.each(@identity_tables, fn table ->
      execute("DROP TRIGGER IF EXISTS #{table}_identity_immutable_guard ON #{@prefix}.#{table}")
    end)

    execute("DROP FUNCTION IF EXISTS #{@prefix}.guard_virtualization_guest_owner_scope()")
    execute("DROP FUNCTION IF EXISTS #{@prefix}.guard_virtualization_identity_immutable()")

    drop_if_exists(
      index(:virtualization_identity_aliases, [:status],
        prefix: @prefix,
        name: :virtualization_identity_aliases_status_idx
      )
    )

    drop_if_exists(
      index(:virtualization_identity_aliases, [:target_provider_ref],
        prefix: @prefix,
        name: :virtualization_identity_aliases_target_ref_idx
      )
    )

    drop_if_exists(
      unique_index(
        :virtualization_identity_aliases,
        [:provider, :resource_kind, :legacy_provider_ref],
        prefix: @prefix,
        name: :virtualization_identity_aliases_legacy_ref_idx
      )
    )

    drop_if_exists(table(:virtualization_identity_aliases, prefix: @prefix))

    Enum.each(@identity_tables, fn table ->
      drop_if_exists(
        unique_index(
          table,
          [
            :provider,
            :integration_id,
            :controller_id,
            :native_cluster_id,
            :object_kind,
            :native_object_id
          ],
          prefix: @prefix,
          name: identity_index_name(table)
        )
      )

      drop_if_exists(
        index(table, [:provider_instance_ref],
          prefix: @prefix,
          name: provider_instance_index_name(table)
        )
      )

      drop_if_exists(constraint(table, identity_complete_constraint_name(table), prefix: @prefix))

      drop_if_exists(constraint(table, identity_state_constraint_name(table), prefix: @prefix))

      drop_if_exists(constraint(table, object_kind_constraint_name(table), prefix: @prefix))

      if table == :virtualization_guests do
        drop_if_exists(
          constraint(table, :virtualization_guests_v3_owner_required, prefix: @prefix)
        )
      end

      alter table(table, prefix: @prefix) do
        remove :identity_version
        remove :identity_state
        remove :integration_id
        remove :controller_id
        remove :native_cluster_id
        remove :object_kind
        remove :native_object_id
        remove :provider_instance_ref
      end
    end)
  end

  defp add_identity_columns(table) do
    alter table(table, prefix: @prefix) do
      add :identity_version, :smallint
      add :identity_state, :text, null: false, default: "legacy"
      add :integration_id, :uuid
      add :controller_id, :uuid
      add :native_cluster_id, :text
      add :object_kind, :text
      add :native_object_id, :text
      add :provider_instance_ref, :text
    end
  end

  defp add_identity_constraints_and_indexes do
    Enum.each(@identity_tables, fn table ->
      create constraint(table, identity_state_constraint_name(table),
               prefix: @prefix,
               check: "identity_state IN ('legacy', 'authoritative', 'quarantined')"
             )

      create constraint(table, identity_complete_constraint_name(table),
               prefix: @prefix,
               check: """
               (identity_version IS NULL
                 AND identity_state IN ('legacy', 'quarantined')
                 AND integration_id IS NULL
                 AND controller_id IS NULL
                 AND provider_instance_ref IS NULL)
               OR (
                 identity_version = 3
                 AND identity_state = 'authoritative'
                 AND integration_id IS NOT NULL
                 AND controller_id IS NOT NULL
                 AND NULLIF(native_cluster_id, '') IS NOT NULL
                 AND NULLIF(object_kind, '') IS NOT NULL
                 AND NULLIF(native_object_id, '') IS NOT NULL
                 AND NULLIF(provider_instance_ref, '') IS NOT NULL
                 AND (provider <> 'proxmox' OR provider_ref LIKE 'proxmox:v3:%')
               )
               """
             )

      create constraint(table, object_kind_constraint_name(table),
               prefix: @prefix,
               check: object_kind_check(table)
             )

      create unique_index(
               table,
               [
                 :provider,
                 :integration_id,
                 :controller_id,
                 :native_cluster_id,
                 :object_kind,
                 :native_object_id
               ],
               prefix: @prefix,
               name: identity_index_name(table),
               where: "identity_version = 3 AND identity_state = 'authoritative'"
             )

      create index(table, [:provider_instance_ref],
               prefix: @prefix,
               name: provider_instance_index_name(table),
               where: "provider_instance_ref IS NOT NULL"
             )
    end)

    create constraint(:virtualization_guests, :virtualization_guests_v3_owner_required,
             prefix: @prefix,
             check: "identity_version IS DISTINCT FROM 3 OR host_id IS NOT NULL"
           )
  end

  # Existing refs can safely reveal native object components, but they cannot
  # reveal which ServiceRadar integration/controller produced the row. Keep
  # them legacy and leave those UUIDs NULL rather than guessing provenance.
  defp backfill_safe_native_components do
    execute("""
    UPDATE #{@prefix}.virtualization_clusters
       SET native_cluster_id = substring(provider_ref FROM '^proxmox:cluster:(.+)$'),
           object_kind = 'cluster',
           native_object_id = substring(provider_ref FROM '^proxmox:cluster:(.+)$')
     WHERE provider = 'proxmox'
       AND provider_ref ~ '^proxmox:cluster:.+$'
       AND identity_version IS NULL
    """)

    execute("""
    UPDATE #{@prefix}.virtualization_hosts h
       SET native_cluster_id = c.native_cluster_id,
           object_kind = 'node',
           native_object_id = substring(h.provider_ref FROM '^proxmox:node:(.+)$')
      FROM #{@prefix}.virtualization_clusters c
     WHERE h.cluster_id = c.id
       AND h.provider = 'proxmox'
       AND h.provider_ref ~ '^proxmox:node:.+$'
       AND h.identity_version IS NULL
    """)

    execute("""
    UPDATE #{@prefix}.virtualization_hosts h
       SET object_kind = 'node',
           native_object_id = substring(h.provider_ref FROM '^proxmox:node:(.+)$')
     WHERE h.provider = 'proxmox'
       AND h.provider_ref ~ '^proxmox:node:.+$'
       AND h.identity_version IS NULL
       AND h.object_kind IS NULL
    """)

    execute("""
    UPDATE #{@prefix}.virtualization_guests g
       SET native_cluster_id = h.native_cluster_id,
           object_kind = CASE
             WHEN lower(g.guest_type) IN ('lxc', 'container') THEN 'lxc'
             ELSE 'qemu'
           END,
           native_object_id = COALESCE(
             g.vmid::text,
             substring(g.provider_ref FROM '^proxmox:guest:[^:]+:[^:]+:([0-9]+)$')
           )
      FROM #{@prefix}.virtualization_hosts h
     WHERE g.host_id = h.id
       AND g.provider = 'proxmox'
       AND g.identity_version IS NULL
    """)
  end

  defp seed_unresolved_legacy_aliases do
    Enum.each(
      [
        {:virtualization_clusters, "cluster"},
        {:virtualization_hosts, "host"},
        {:virtualization_guests, "guest"}
      ],
      fn {table, resource_kind} ->
        execute("""
        INSERT INTO #{@prefix}.virtualization_identity_aliases (
          id,
          provider,
          resource_kind,
          legacy_provider_ref,
          status,
          reason,
          candidate_provider_refs,
          metadata,
          inserted_at,
          updated_at
        )
        SELECT
          gen_random_uuid(),
          provider,
          '#{resource_kind}',
          provider_ref,
          'unresolved',
          'missing_integration_controller_provenance',
          ARRAY[]::text[],
          jsonb_build_object('legacy_row_id', id::text),
          now() AT TIME ZONE 'utc',
          now() AT TIME ZONE 'utc'
        FROM #{@prefix}.#{table}
        WHERE provider = 'proxmox'
          AND identity_version IS NULL
        ON CONFLICT (provider, resource_kind, legacy_provider_ref) DO NOTHING
        """)
      end
    )
  end

  defp create_identity_guards do
    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.guard_virtualization_identity_immutable()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NEW.provider = 'proxmox' AND NEW.identity_version IS DISTINCT FROM 3 THEN
          RAISE EXCEPTION 'new Proxmox virtualization identities must be authoritative v3'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END IF;

      IF NEW.provider = 'proxmox' AND OLD.provider IS DISTINCT FROM 'proxmox' THEN
        RAISE EXCEPTION 'ordinary updates cannot claim Proxmox identity provenance'
          USING ERRCODE = '23514';
      END IF;

      IF (OLD.provider = 'proxmox' OR OLD.identity_version = 3) AND ROW(
        OLD.provider,
        OLD.provider_ref,
        OLD.identity_version,
        OLD.identity_state,
        OLD.integration_id,
        OLD.controller_id,
        OLD.native_cluster_id,
        OLD.object_kind,
        OLD.native_object_id,
        OLD.provider_instance_ref
      ) IS DISTINCT FROM ROW(
        NEW.provider,
        NEW.provider_ref,
        NEW.identity_version,
        NEW.identity_state,
        NEW.integration_id,
        NEW.controller_id,
        NEW.native_cluster_id,
        NEW.object_kind,
        NEW.native_object_id,
        NEW.provider_instance_ref
      ) THEN
        RAISE EXCEPTION 'authoritative virtualization identity is immutable'
          USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    Enum.each(@identity_tables, fn table ->
      execute("""
      CREATE TRIGGER #{table}_identity_immutable_guard
      BEFORE INSERT OR UPDATE ON #{@prefix}.#{table}
      FOR EACH ROW
      EXECUTE FUNCTION #{@prefix}.guard_virtualization_identity_immutable()
      """)
    end)

    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.guard_virtualization_guest_owner_scope()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      owner #{@prefix}.virtualization_hosts%ROWTYPE;
    BEGIN
      IF NEW.identity_version = 3 AND NEW.host_id IS NOT NULL THEN
        SELECT * INTO owner
          FROM #{@prefix}.virtualization_hosts
         WHERE id = NEW.host_id;

        IF NOT FOUND OR owner.identity_version IS DISTINCT FROM 3 OR ROW(
          owner.provider,
          owner.integration_id,
          owner.controller_id,
          owner.native_cluster_id
        ) IS DISTINCT FROM ROW(
          NEW.provider,
          NEW.integration_id,
          NEW.controller_id,
          NEW.native_cluster_id
        ) OR owner.object_kind IS DISTINCT FROM 'node' THEN
          RAISE EXCEPTION 'virtualization guest owner must be the exact source-scoped v3 node'
            USING ERRCODE = '23514';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER virtualization_guest_owner_scope_guard
    BEFORE INSERT OR UPDATE OF host_id, provider, identity_version, integration_id,
      controller_id, native_cluster_id ON #{@prefix}.virtualization_guests
    FOR EACH ROW
    EXECUTE FUNCTION #{@prefix}.guard_virtualization_guest_owner_scope()
    """)
  end

  defp identity_index_name(table), do: String.to_atom("#{table}_source_identity_v3_idx")

  defp provider_instance_index_name(table),
    do: String.to_atom("#{table}_provider_instance_ref_idx")

  defp identity_state_constraint_name(table), do: String.to_atom("#{table}_identity_state_valid")

  defp identity_complete_constraint_name(table),
    do: String.to_atom("#{table}_identity_v3_complete")

  defp object_kind_constraint_name(table), do: String.to_atom("#{table}_object_kind_valid")

  defp object_kind_check(:virtualization_clusters),
    do: "provider <> 'proxmox' OR identity_version IS DISTINCT FROM 3 OR object_kind = 'cluster'"

  defp object_kind_check(:virtualization_hosts),
    do: "provider <> 'proxmox' OR identity_version IS DISTINCT FROM 3 OR object_kind = 'node'"

  defp object_kind_check(:virtualization_guests),
    do:
      "provider <> 'proxmox' OR identity_version IS DISTINCT FROM 3 OR object_kind IN ('qemu', 'lxc')"
end
