defmodule ServiceRadar.Repo.Migrations.ArchiveDisplacedBridgeIdentityAliases do
  @moduledoc """
  Archives displaced container-bridge and CNI `:ip` aliases retained when
  hypervisor enrichment restored a device's real primary address (GitHub #5848).

  Before #5838, `GuestAddress.primary/1` could pick a container-bridge or CNI
  interface address ahead of the hypervisor-attached NIC. When the next
  enrichment pass restored the LAN primary IP, `Sync.Aliases.retain_replaced_address/2`
  recorded the displaced bridge address as a `:detected` `:ip` alias with
  `metadata->>'source' = 'replaced_primary_address'`. Because `:detected` `:ip`
  aliases are still consulted by `MapperResultsIngestor.find_device_uid_by_alias/3`,
  `DeviceLookup` (`include_detected: true`), device flow attribution, and the
  device detail IP Aliases table, those leftover bridge rows remain active until
  archived.

  This migration archives only `device_alias_states` rows where:
  - `alias_type = 'ip'`, `state <> 'archived'`, and
    `metadata ->> 'source' = 'replaced_primary_address'`;
  - the alias value is not the device's current primary `ip`;
  - the alias value sits on a non-`config` guest/host interface or discovered
    interface of the same device whose name matches
    `GuestAddress.host_internal_name?/1`; and
  - no `config` or non-host-internal interface of the same device carries that
    address.

  serviceradar:allow-startup-maintenance - the repair UPDATE touches only
  unarchived `replaced_primary_address` `:ip` alias rows corroborated against a
  host-internal bridge/CNI interface of the same device, uses a 5s lock timeout,
  and selects target rows with `FOR NO KEY UPDATE SKIP LOCKED` so it never blocks
  concurrent writers.
  """

  use Ecto.Migration

  alias ServiceRadar.Inventory.Identity.GuestAddress

  def up do
    schema = prefix() || "platform"

    execute("SET LOCAL lock_timeout = '5s'")
    execute(repair_sql(schema))
  end

  def down do
    :ok
  end

  @doc false
  def repair_sql(schema \\ "platform") do
    vni_host_internal = GuestAddress.host_internal_name_sql("vni.name")
    di_host_internal = GuestAddress.host_internal_name_sql("di.if_name")

    """
    WITH candidates AS (
      SELECT das.id
      FROM #{schema}.device_alias_states AS das
      WHERE das.alias_type = 'ip'
        AND das.state <> 'archived'
        AND COALESCE(das.metadata, '{}'::jsonb) ->> 'source' = 'replaced_primary_address'
        AND NOT EXISTS (
          SELECT 1
          FROM #{schema}.ocsf_devices AS d
          WHERE d.uid = das.device_id
            AND d.deleted_at IS NULL
            AND btrim(COALESCE(d.ip, '')) = btrim(split_part(das.alias_value, '/', 1))
        )
        AND (
          EXISTS (
            SELECT 1
            FROM #{schema}.virtualization_network_interfaces AS vni
            WHERE #{vni_belongs_to_device_sql(schema, "vni", "das.device_id")}
              AND vni.exists IS DISTINCT FROM false
              AND NOT #{vni_config_source_sql("vni")}
              AND #{vni_host_internal}
              AND #{vni_carries_ip_sql("vni", "das.alias_value")}
          )
          OR EXISTS (
            SELECT 1
            FROM #{schema}.discovered_interfaces AS di
            WHERE di.device_id = das.device_id
              AND #{di_host_internal}
              AND #{di_carries_ip_sql("di", "das.alias_value")}
          )
        )
        AND NOT EXISTS (
          SELECT 1
          FROM #{schema}.virtualization_network_interfaces AS vni
          WHERE #{vni_belongs_to_device_sql(schema, "vni", "das.device_id")}
            AND vni.exists IS DISTINCT FROM false
            AND (#{vni_config_source_sql("vni")} OR NOT (#{vni_host_internal}))
            AND #{vni_carries_ip_sql("vni", "das.alias_value")}
        )
        AND NOT EXISTS (
          SELECT 1
          FROM #{schema}.discovered_interfaces AS di
          WHERE di.device_id = das.device_id
            AND NOT (#{di_host_internal})
            AND #{di_carries_ip_sql("di", "das.alias_value")}
        )
      FOR NO KEY UPDATE OF das SKIP LOCKED
    )
    UPDATE #{schema}.device_alias_states AS das
    SET state = 'archived',
        updated_at = timezone('utc', now())
    FROM candidates
    WHERE das.id = candidates.id
    """
  end

  defp vni_belongs_to_device_sql(schema, vni_alias, device_id_expr) do
    """
    (
      #{vni_alias}.device_uid = #{device_id_expr}
      OR EXISTS (
        SELECT 1
        FROM #{schema}.virtualization_guests AS vg
        WHERE vg.id = #{vni_alias}.guest_id
          AND vg.device_uid = #{device_id_expr}
      )
      OR (
        #{vni_alias}.guest_id IS NULL
        AND EXISTS (
          SELECT 1
          FROM #{schema}.virtualization_hosts AS vh
          WHERE vh.id = #{vni_alias}.host_id
            AND vh.device_uid = #{device_id_expr}
        )
      )
    )
    """
  end

  defp vni_config_source_sql(vni_alias) do
    """
    EXISTS (
      SELECT 1
      FROM regexp_split_to_table(COALESCE(#{vni_alias}.source, ''), ',') AS src_tok
      WHERE btrim(src_tok) = 'config'
    )
    """
  end

  defp vni_carries_ip_sql(vni_alias, alias_value_expr) do
    """
    EXISTS (
      SELECT 1
      FROM unnest(
        COALESCE(#{vni_alias}.ip_addresses, ARRAY[]::text[]) ||
          ARRAY[#{vni_alias}.cidr, #{vni_alias}.address]
      ) AS raw_ip
      WHERE raw_ip IS NOT NULL
        AND btrim(split_part(raw_ip, '/', 1)) = btrim(split_part(#{alias_value_expr}, '/', 1))
    )
    """
  end

  defp di_carries_ip_sql(di_alias, alias_value_expr) do
    """
    EXISTS (
      SELECT 1
      FROM unnest(COALESCE(#{di_alias}.ip_addresses, ARRAY[]::text[])) AS raw_ip
      WHERE raw_ip IS NOT NULL
        AND btrim(split_part(raw_ip, '/', 1)) = btrim(split_part(#{alias_value_expr}, '/', 1))
    )
    """
  end
end
