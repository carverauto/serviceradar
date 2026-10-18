defmodule ServiceRadar.Repo.Migrations.ArchiveBroadcastIdentityAliases do
  @moduledoc """
  Archive leftover IPv4 broadcast identity aliases and strip broadcast IPs from
  device metadata and discovered interfaces.

  Writer-side `AliasPolicy` and SNMP/MikroTik mapper filters stop new broadcast
  addresses (`255.255.255.255` and subnet directed broadcast addresses for prefix
  lengths `0..30`) from becoming `:ip` or `:interface_ip` aliases, and DIRE
  `broadcast-alias-archive` is the replayable sweeper; this migration makes the
  cleanup execute-on-deploy (GitHub #5743).
  """
  use Ecto.Migration

  alias ServiceRadar.Inventory.Remediation.BroadcastAliasArchive

  def up do
    schema = prefix() || "platform"
    ctes = BroadcastAliasArchive.broadcast_ctes(schema)

    execute("""
    #{ctes}
    UPDATE #{schema}.device_alias_states AS das
    SET state = 'archived',
        updated_at = timezone('utc', now())
    WHERE das.alias_type IN ('ip', 'interface_ip')
      AND das.state <> 'archived'
      AND #{BroadcastAliasArchive.alias_broadcast_predicate("das.device_id", "das.alias_value")}
    """)

    execute("""
    #{ctes}
    UPDATE #{schema}.ocsf_devices AS d
    SET metadata = d.metadata - k.keys,
        modified_time = timezone('utc', now())
    FROM (
      SELECT
        d_inner.uid,
        ARRAY(
          SELECT key
          FROM jsonb_object_keys(d_inner.metadata) AS key
          WHERE (
            key LIKE 'ip_alias:%'
            AND #{BroadcastAliasArchive.alias_broadcast_predicate("d_inner.uid", "substring(key from 10)")}
          ) OR (
            key LIKE 'interface_ip_alias:%'
            AND #{BroadcastAliasArchive.alias_broadcast_predicate("d_inner.uid", "substring(key from 20)")}
          )
        ) AS keys
      FROM #{schema}.ocsf_devices d_inner
      WHERE jsonb_typeof(d_inner.metadata) = 'object'
    ) AS k
    WHERE d.uid = k.uid
      AND cardinality(k.keys) > 0
    """)

    execute("""
    #{ctes}
    UPDATE #{schema}.discovered_interfaces AS di
    SET ip_addresses = ARRAY(
      SELECT ip
      FROM unnest(di.ip_addresses) AS ip
      WHERE NOT (#{BroadcastAliasArchive.alias_broadcast_predicate("di.device_id", "ip")})
    )
    WHERE COALESCE(array_length(di.ip_addresses, 1), 0) > 0
      AND EXISTS (
        SELECT 1
        FROM unnest(di.ip_addresses) AS ip
        WHERE #{BroadcastAliasArchive.alias_broadcast_predicate("di.device_id", "ip")}
      )
    """)
  end

  def down do
    raise "cannot restore archived broadcast identity aliases"
  end
end
