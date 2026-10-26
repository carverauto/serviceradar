defmodule ServiceRadar.Repo.Migrations.IndexIdentityLookupPaths do
  @moduledoc """
  Indexes two identity lookups that read whole tables.

    * `device_source_observations_armis_mac_tokens_gin_idx`: the MAC tokens of Armis source
      observations. The succession pass's MAC lookup (`SourceSuccession`, the live records
      reporting one of a set of MACs) compares the MAC tokens of four columns with the wanted
      MACs. Migration 20260709210000 indexed the token expression on `ocsf_devices.mac` and on
      the MAC rows of `device_identifiers`, and `device_interface_macs.mac` is compared
      directly, but `device_source_observations.mac` had no index: each of the lookup's two
      observation arms read every Armis observation and split its MAC with a regular
      expression. The lookup runs once per duplicate pass and once per succession merge,
      inside the merge transaction. The observation MAC is stored as the source reported it
      (any separator or case, sometimes several MACs in one value), so the index is on the
      same token expression, which normalizes every stored form; an expression index must
      match the query text exactly, and its predicate matches the lookup's
      `o.source = 'armis' AND o.mac IS NOT NULL`.

    * `ocsf_devices_live_awx_records_idx`: the live AWX host records. Hypervisor enrichment
      matches each guest of a result against the AWX records (`HypervisorEnrichmentIngestor`,
      the guest candidates), which read every live device to test the AWX condition. The
      partial index holds only the AWX records, and its predicate is that condition, which the
      query must repeat exactly.

  Built `CONCURRENTLY`, which takes a lock that never blocks writes to either table and cannot
  run inside a transaction, hence the disabled DDL transaction and migration lock. No
  `lock_timeout` is set: outside a transaction it could only be set for the session, which a
  pooled connection would carry to later work. An interrupted build leaves an invalid index,
  which the next run drops and rebuilds.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @indexes [
    {"device_source_observations_armis_mac_tokens_gin_idx",
     """
     CREATE INDEX CONCURRENTLY IF NOT EXISTS device_source_observations_armis_mac_tokens_gin_idx
     ON platform.device_source_observations
     USING GIN ((
       regexp_split_to_array(
         upper(translate(mac, ':-.', '')),
         '[,;[:space:]]+'
       )
     ))
     WHERE source = 'armis' AND mac IS NOT NULL
     """},
    {"ocsf_devices_live_awx_records_idx",
     """
     CREATE INDEX CONCURRENTLY IF NOT EXISTS ocsf_devices_live_awx_records_idx
     ON platform.ocsf_devices (uid)
     WHERE deleted_at IS NULL
       AND (
         'awx' = ANY(COALESCE(discovery_sources, ARRAY[]::text[]))
         OR COALESCE(metadata->>'integration_type', '') = 'awx'
         OR COALESCE(metadata, '{}'::jsonb) ? 'awx'
       )
     """}
  ]

  def up do
    Enum.each(@indexes, fn {name, create} ->
      case index_state(name) do
        :valid ->
          :ok

        :invalid ->
          execute("DROP INDEX CONCURRENTLY IF EXISTS platform.#{name}")
          execute(create)

        :missing ->
          execute(create)
      end
    end)
  end

  def down do
    Enum.each(@indexes, fn {name, _create} ->
      execute("DROP INDEX CONCURRENTLY IF EXISTS platform.#{name}")
    end)
  end

  defp index_state(name) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT COALESCE(i.indisvalid AND i.indisready AND i.indislive, false)
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        JOIN pg_index AS i ON i.indexrelid = c.oid
        WHERE n.nspname = 'platform' AND c.relname = $1
        """,
        [name]
      )

    case rows do
      [] -> :missing
      [[true]] -> :valid
      [[false]] -> :invalid
    end
  end
end
