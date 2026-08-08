defmodule ServiceRadar.Repo.Migrations.CreateColdTierExportRole do
  @moduledoc """
  Read-only export role on the primary for the cold-tier analytics head
  (OpenSpec add-tiered-telemetry-offload, task 1.6; design D6).

  The analytics head reads hot rows through `postgres_fdw` as this role — it
  is the ONLY path from the head into the primary, so it is scoped to
  SELECT on the registry tables plus the cold-tier manifest, and carries
  role-level timeouts so a hung export can never pin a snapshot forever
  (each export COPY holds `backend_xmin` for its whole runtime — verified in
  spike 0.2).

  Grants and settings live here (schema concerns); the password lives in the
  deployment. In Kubernetes the reliable owner is CNPG `managed.roles` +
  a password Secret (reconciled continuously, survives migration ordering),
  rendered by the chart only when `coldTier.exportRole.enabled` is set; the
  local compose/dev loop bootstraps it from
  `SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD[_FILE]` here.

  ## Unusable by construction on deployments that never enable the cold tier

  The role is created `NOLOGIN`. `LOGIN` is granted only in the same step that
  sets a password, i.e. only when a deployment supplies the FDW credential.

  This matters because the two are not equivalent. A `LOGIN` role with no
  password is unusable only as long as the cluster's `pg_hba.conf` demands one
  -- it is an absence of a credential, not an absence of capability, so a
  `trust`/`peer` line, a `.pgpass`, or a later `ALTER ROLE` reaches straight
  through it. `NOLOGIN` is refused before authentication is consulted at all.
  On the overwhelmingly common deployment, which never turns the cold tier on,
  the role should not be a thing that could connect.

  An existing role's login state is deliberately NOT reset on re-run: a live
  cold tier whose password CNPG owns must not be locked out by a migration.
  """

  use Ecto.Migration

  @role "cold_reader"

  # Bounds concurrent cold_reader sessions so a runaway can't exhaust the
  # primary's connection slots, while leaving headroom for the expected mix:
  # the exporter's export/verify sessions plus concurrent stitched-view
  # analytics reads (each head query that touches hot data opens/reuses one
  # cold_reader connection via postgres_fdw). Raise via a follow-up ALTER if a
  # deployment runs a larger ColdRepo pool. Not unlimited (review F24).
  @connection_limit 10

  # Keep in sync with ServiceRadar.ColdTier.Registry (the registry drift test
  # covers columns; this list covers grants).
  @registry_tables ~w(
    logs
    otel_traces
    otel_metrics
    otel_metric_points
    timeseries_metrics
    ocsf_events
    ocsf_network_activity
  )

  def up do
    # Role DDL is a CLUSTER-admin privilege, and the migration user does not
    # have it on a default CNPG cluster -- the app user is the database owner,
    # not a superuser and not CREATEROLE. `CREATE ROLE` there fails with
    # "permission denied to create role", and because Ecto aborts the whole run
    # on a failed migration, an unguarded CREATE ROLE here does not just skip
    # the cold tier: it takes down every migration after it, so a fresh install
    # cannot provision and an upgrade cannot proceed. Verified against the
    # srql-fixtures cluster (current_user srql: rolsuper=f, rolcreaterole=f).
    #
    # So the role is created only where the migration is actually entitled to.
    # Everywhere else there is a designated owner that IS entitled: CNPG
    # `managed.roles` in Kubernetes (rendered by the chart when
    # coldTier.exportRole.enabled), or a superuser bootstrap in compose. The
    # grants below then apply to whatever created it.
    execute("""
    DO $$
    DECLARE
      may_manage_roles boolean;
    BEGIN
      SELECT rolsuper OR rolcreaterole
      INTO may_manage_roles
      FROM pg_roles
      WHERE rolname = current_user;

      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        -- CONNECTION LIMIT only. Login state belongs to whoever provisioned
        -- the credential (CNPG managed.roles, or the password branch below);
        -- re-running migrations must not revoke a working cold tier's access.
        IF may_manage_roles THEN
          ALTER ROLE #{@role} CONNECTION LIMIT #{@connection_limit};
        END IF;
      ELSIF may_manage_roles THEN
        CREATE ROLE #{@role} NOLOGIN CONNECTION LIMIT #{@connection_limit};
      ELSE
        RAISE NOTICE
          'Skipping cold-tier % role: % lacks CREATEROLE. This is expected on a '
          'default CNPG cluster and only matters if you enable the cold tier, '
          'where CNPG managed.roles (coldTier.exportRole.enabled) creates it '
          'instead. Re-run migrations afterwards to attach the grants.',
          '#{@role}', current_user;
      END IF;
    END $$;
    """)

    # Read-only scope: usage on the schema, SELECT on registry tables + the
    # manifest. No writes, no other tables. All guarded on the role existing,
    # since it legitimately may not (see above) -- granting to a missing role
    # is an error, and this migration must never be the thing that fails.
    #
    # No `_timescaledb_internal` grant is needed: TimescaleDB propagates the
    # hypertable parent's ACL to every chunk, including chunks created AFTER
    # this grant (verified against the live engine). Granting the internal
    # schema instead would (a) expose chunks of NON-registry hypertables the
    # export never touches and (b) create an `ALTER DEFAULT PRIVILEGES`
    # dependency that blocks `DROP ROLE` (review F24/F25).
    execute(if_role_exists("EXECUTE 'GRANT USAGE ON SCHEMA platform TO #{@role}';"))

    for table <- @registry_tables ++ ~w(cold_chunk_exports cold_tier_boundaries) do
      execute(
        if_role_exists("""
        IF EXISTS (
          SELECT 1 FROM information_schema.tables
          WHERE table_schema = 'platform' AND table_name = '#{table}'
        ) THEN
          EXECUTE 'GRANT SELECT ON platform.#{table} TO #{@role}';
        END IF;
        """)
      )
    end

    # Role-level bounds: a stuck export must not pin the vacuum horizon or
    # hold a connection forever. Export units are chunk-sized (seconds to
    # tens of seconds); these are generous ceilings, not tuning knobs.
    #
    # ALTER ROLE ... SET on ANOTHER role also needs CREATEROLE, so these carry
    # the same guard as the creation above.
    #
    # Issued as PLAIN statements rather than EXECUTE. They are not dynamic --
    # the role name is a compile-time constant -- and their values contain
    # quotes, which under EXECUTE have to survive two levels of literal
    # escaping. Getting that wrong is not a subtle failure: it is a syntax
    # error that aborts the migration, i.e. the exact thing this migration must
    # never do. Not nesting removes the hazard rather than escaping around it.
    for setting <- [
          "statement_timeout = '300s'",
          "idle_in_transaction_session_timeout = '120s'",
          "lock_timeout = '10s'"
        ] do
      execute(if_role_manageable("ALTER ROLE #{@role} SET #{setting};"))
    end

    # Supplying the FDW credential IS the local enablement signal, so this is
    # where LOGIN is granted -- the role gains the ability to connect and the
    # means to do it in one step, and never one without the other.
    case fdw_password() do
      password when is_binary(password) and password != "" ->
        escaped = String.replace(password, "'", "''")

        execute(if_role_manageable("ALTER ROLE #{@role} LOGIN PASSWORD '#{escaped}';"))

      _ ->
        :ok
    end
  end

  def down do
    # No default-ACL dependency to unwind (see up/0), so DROP ROLE succeeds
    # after the explicit grants are revoked. Same privilege guard: a migration
    # user that could not create the role cannot drop it either, and rolling
    # back must not fail on that.
    execute(
      if_role_manageable("""
      REVOKE ALL ON ALL TABLES IN SCHEMA platform FROM #{@role};
      REVOKE ALL ON SCHEMA platform FROM #{@role};
      DROP ROLE #{@role};
      """)
    )
  end

  # Wraps `body` so it runs only when the export role is present.
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

  # Wraps `body` so it runs only when the export role is present AND this
  # connection is entitled to alter it.
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

  # The migrations container does not always receive the raw env (the compose
  # override attaches the cold-tier env file only to the runtime service, not
  # migrations), so also accept the secret via a mounted `_FILE` path — the
  # convention every other cold-tier secret already supports (review F19).
  defp fdw_password do
    direct = System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD")

    cond do
      is_binary(direct) and direct != "" ->
        direct

      path = System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD_FILE") ->
        case File.read(path) do
          {:ok, contents} -> String.trim(contents)
          _ -> nil
        end

      true ->
        nil
    end
  end
end
