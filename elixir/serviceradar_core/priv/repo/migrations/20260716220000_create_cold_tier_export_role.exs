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
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        CREATE ROLE #{@role} NOLOGIN CONNECTION LIMIT #{@connection_limit};
      ELSE
        -- CONNECTION LIMIT only. Login state belongs to whoever provisioned
        -- the credential (CNPG managed.roles, or the password branch below);
        -- re-running migrations must not revoke a working cold tier's access.
        ALTER ROLE #{@role} CONNECTION LIMIT #{@connection_limit};
      END IF;
    END $$;
    """)

    # Read-only scope: usage on the schema, SELECT on registry tables + the
    # manifest. No writes, no other tables.
    #
    # No `_timescaledb_internal` grant is needed: TimescaleDB propagates the
    # hypertable parent's ACL to every chunk, including chunks created AFTER
    # this grant (verified against the live engine). Granting the internal
    # schema instead would (a) expose chunks of NON-registry hypertables the
    # export never touches and (b) create an `ALTER DEFAULT PRIVILEGES`
    # dependency that blocks `DROP ROLE` (review F24/F25).
    execute("GRANT USAGE ON SCHEMA platform TO #{@role}")

    for table <- @registry_tables ++ ~w(cold_chunk_exports cold_tier_boundaries) do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.tables
          WHERE table_schema = 'platform' AND table_name = '#{table}'
        ) THEN
          EXECUTE 'GRANT SELECT ON platform.#{table} TO #{@role}';
        END IF;
      END $$;
      """)
    end

    # Role-level bounds: a stuck export must not pin the vacuum horizon or
    # hold a connection forever. Export units are chunk-sized (seconds to
    # tens of seconds); these are generous ceilings, not tuning knobs.
    execute("ALTER ROLE #{@role} SET statement_timeout = '300s'")
    execute("ALTER ROLE #{@role} SET idle_in_transaction_session_timeout = '120s'")
    execute("ALTER ROLE #{@role} SET lock_timeout = '10s'")

    # Supplying the FDW credential IS the local enablement signal, so this is
    # where LOGIN is granted -- the role gains the ability to connect and the
    # means to do it in one step, and never one without the other.
    case fdw_password() do
      password when is_binary(password) and password != "" ->
        execute("ALTER ROLE #{@role} LOGIN PASSWORD '#{String.replace(password, "'", "''")}'")

      _ ->
        :ok
    end
  end

  def down do
    # No default-ACL dependency to unwind (see up/0), so DROP ROLE succeeds
    # after the explicit grants are revoked.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA platform FROM #{@role}';
        EXECUTE 'REVOKE ALL ON SCHEMA platform FROM #{@role}';
        DROP ROLE #{@role};
      END IF;
    END $$;
    """)
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
