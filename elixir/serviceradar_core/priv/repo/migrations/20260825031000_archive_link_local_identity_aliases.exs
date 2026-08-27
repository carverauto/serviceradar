defmodule ServiceRadar.Repo.Migrations.ArchiveLinkLocalIdentityAliases do
  @moduledoc """
  Archive leftover link-local identity aliases and strip matching metadata.

  Writer-side `AliasPolicy` stops new `fe80::/10` and `169.254/16` rows, but
  identity *readers* still consult existing `:ip` (and `:interface_ip`) alias
  rows. GitHub #4022 measured 4 of 5 bad merge candidates keyed on `fe80::`.
  DIRE `link-local-alias-archive` is the replayable sweeper; this migration
  makes the cleanup execute-on-deploy instead of waiting on `mix
  serviceradar.dire_remediation`.

  Archives, does not mark stale: `:stale` is still a mapper lookup candidate
  and `maybe_reactivate_alias/2` revives it.

  Classification uses `platform.sr_address_rank` (rank 20 = link-local),
  which already strips `%zone` and `/cidr`.
  """
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    execute("""
    UPDATE #{schema}.device_alias_states
    SET state = 'archived',
        updated_at = timezone('utc', now())
    WHERE alias_type IN ('ip', 'interface_ip')
      AND state <> 'archived'
      AND #{schema}.sr_address_rank(alias_value) = 20
    """)

    execute("""
    UPDATE #{schema}.ocsf_devices AS d
    SET metadata = d.metadata - k.keys,
        modified_time = timezone('utc', now())
    FROM (
      SELECT
        uid,
        ARRAY(
          SELECT key
          FROM jsonb_object_keys(metadata) AS key
          WHERE key LIKE 'ip_alias:%'
            AND #{schema}.sr_address_rank(substring(key from 10)) = 20
        ) AS keys
      FROM #{schema}.ocsf_devices
      WHERE jsonb_typeof(metadata) = 'object'
    ) AS k
    WHERE d.uid = k.uid
      AND cardinality(k.keys) > 0
    """)
  end

  def down do
    raise "cannot restore archived link-local identity aliases"
  end
end
