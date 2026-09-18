defmodule ServiceRadar.Repo.Migrations.CreateStarrocksCatalogReaderRole do
  @moduledoc """
  Owns the `serviceradar_starrocks_reader` role and its complete grant set.

  The StarRocks Frontend reads CNPG current-state through the `cnpg_platform`
  JDBC catalog as this role and nothing else does, so it is scoped to SELECT on
  the six allowlisted objects, column-scoped to exactly what the compiled
  catalog subqueries read.

  Grants live here (schema concerns); the credential lives in the deployment.
  In Kubernetes the reliable owner is CNPG `managed.roles` + a password Secret,
  rendered by the chart only when `analytics.starrocks.catalog.enabled` is set.

  ## Unusable by construction on deployments that never enable the catalog

  The role is created `NOLOGIN`, for the reason
  `20260716220000_create_cold_tier_export_role` already sets out: a `LOGIN` role
  with no password is unusable only as long as the cluster's `pg_hba.conf`
  demands one -- an absence of a credential, not of capability, which a
  `trust`/`peer` line or a later `ALTER ROLE` reaches straight through. The
  catalog is off by default, and Compose and developer databases are not covered
  by the chart's pg_hba, so on the common deployment this role must not be a
  thing that could connect. `LOGIN` is granted by whoever supplies the password.

  An existing role's login state is deliberately NOT reset on re-run: a live
  catalog whose password CNPG owns must not be locked out by a migration.
  """

  use Ecto.Migration

  @role "serviceradar_starrocks_reader"

  # Keep in sync with ServiceRadar.Analytics.StarRocks.CatalogAllowlist. Column
  # lists match what rust/srql compiles into catalog joins and subqueries;
  # `nil` means the whole relation.
  @grants [
    {"prefix_tags_catalog", nil},
    {"netflow_local_cidrs_catalog", nil},
    {"ocsf_devices", "uid, hostname, ip"},
    {"device_alias_states", "device_id, alias_type, state, alias_value"},
    {"netflow_exporter_cache", "device_uid, sampler_address"}
  ]

  def up do
    # Role DDL is a CLUSTER-admin privilege the migration user does not have on
    # a default CNPG cluster -- the app user is the database owner, not a
    # superuser and not CREATEROLE. An unguarded CREATE ROLE does not merely
    # skip the catalog: Ecto aborts the whole run on a failed migration, so it
    # takes down every migration after it and a core pod that reaches such a
    # database never starts. The role is therefore created only where this
    # connection is entitled to; everywhere else CNPG `managed.roles` creates
    # it (rendered when analytics.starrocks.catalog.enabled), and the grants
    # below then apply to whatever created it.
    execute("""
    DO $$
    DECLARE
      may_manage_roles boolean;
    BEGIN
      SELECT rolsuper OR rolcreaterole
      INTO may_manage_roles
      FROM pg_roles
      WHERE rolname = current_user;

      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        IF may_manage_roles THEN
          CREATE ROLE #{@role} NOLOGIN;
        ELSE
          RAISE NOTICE
            'Skipping % role: % lacks CREATEROLE. This is expected on a default '
            'CNPG cluster and only matters if you enable the StarRocks JDBC '
            'catalog, where CNPG managed.roles '
            '(analytics.starrocks.catalog.enabled) creates it instead. Re-run '
            'migrations afterwards to attach the grants.',
            '#{@role}', current_user;
        END IF;
      END IF;
    END $$;
    """)

    # All guarded on the role existing, since it legitimately may not (see
    # above) -- granting to a missing role is an error, and this migration must
    # never be the thing that fails.
    execute(
      if_role_exists("""
      EXECUTE format('GRANT CONNECT ON DATABASE %I TO #{@role}', current_database());
      EXECUTE 'GRANT USAGE ON SCHEMA platform TO #{@role}';
      """)
    )

    for {relation, columns} <- @grants do
      execute(if_role_exists(grant_sql("GRANT", relation, columns, "TO")))
    end
  end

  def down do
    for {relation, columns} <- Enum.reverse(@grants) do
      execute(if_role_exists(grant_sql("REVOKE", relation, columns, "FROM")))
    end

    execute(
      if_role_exists("""
      EXECUTE 'REVOKE USAGE ON SCHEMA platform FROM #{@role}';
      EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM #{@role}', current_database());
      """)
    )

    # Same privilege guard as up/0: a migration user that could not create the
    # role cannot drop it either, and rolling back must not fail on that.
    execute(if_role_manageable("EXECUTE 'DROP ROLE #{@role}';"))
  end

  defp grant_sql(verb, relation, nil, preposition) do
    """
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'platform' AND table_name = '#{relation}'
    ) THEN
      EXECUTE '#{verb} SELECT ON platform.#{relation} #{preposition} #{@role}';
    END IF;
    """
  end

  defp grant_sql(verb, relation, columns, preposition) do
    """
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'platform' AND table_name = '#{relation}'
    ) THEN
      EXECUTE '#{verb} SELECT (#{columns}) ON platform.#{relation} #{preposition} #{@role}';
    END IF;
    """
  end

  defp if_role_exists(body) do
    """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        #{body}
      END IF;
    END $$;
    """
  end

  defp if_role_manageable(body) do
    """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}')
         AND EXISTS (
           SELECT 1 FROM pg_roles
           WHERE rolname = current_user AND (rolsuper OR rolcreaterole)
         ) THEN
        #{body}
      END IF;
    END $$;
    """
  end
end
