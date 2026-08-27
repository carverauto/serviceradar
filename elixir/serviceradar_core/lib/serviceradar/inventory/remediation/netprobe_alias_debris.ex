defmodule ServiceRadar.Inventory.Remediation.NetprobeAliasDebris do
  @moduledoc """
  Step `netprobe-alias-debris`.

  Removes the addresses a collector absorbed from hosts it merely observed.

  A passive netprobe fingerprint used to identify the COLLECTOR rather than the
  host it described, because the agent stamps the collector's `agent_id` on every
  fingerprint update and `passive-netprobe` was missing from
  `SourcePolicy.observer_agent_source?/1`. Each observed host therefore left its
  address behind on the collector's own device, as an `ip_alias:<addr>` metadata
  key and a matching `device_alias_states` row. The forward fix reclassified the
  source; it does not undo what already landed.

  This debris is NOT inert. `MapperResultsIngestor.find_device_uid_by_alias/3`
  looks aliases up by value with no state filter and rejects only `:replaced` and
  `:archived` -- so a `:stale` row is still a candidate, and
  `maybe_reactivate_alias/2` REVIVES it. On the deployment this was measured on,
  four addresses had exactly one `:ip` alias row apiece and all four named the
  wrong device, with the real owners carrying no alias row to outrank it.

  Which is why this archives rather than marking stale: `:stale` is a revivable
  state that the mapper still consults, so marking stale would look like a
  cleanup and quietly undo itself.

  Both halves of a device's debris -- metadata keys and alias rows -- move in one
  transaction. Leaving either behind leaves the mis-attribution working.

  The selection rule is `Decisions.plan_netprobe_alias_purge/1`; every guard it
  applies is there to protect a legitimate alias, and the reasons it skips for
  are reported so the excluded population is visible rather than assumed empty.
  """

  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "netprobe-alias-debris"

  @doc false
  def run(mode, opts, manifest, actor) do
    candidates = candidates(opts)

    {plans, skips} =
      Enum.reduce(candidates, {[], %{}}, fn device, {plans, skips} ->
        case Decisions.plan_netprobe_alias_purge(device) do
          {:purge, addresses} -> {[{device, addresses} | plans], skips}
          {:skip, reason} -> {plans, Map.update(skips, reason, 1, &(&1 + 1))}
        end
      end)

    plans = Enum.reverse(plans)

    base = %{
      examined_devices: length(candidates),
      affected_devices: length(plans),
      absorbed_addresses: plans |> Enum.map(fn {_d, a} -> length(a) end) |> Enum.sum(),
      skipped: skips
    }

    case mode do
      :dry_run ->
        Map.put(
          base,
          :would_purge,
          Enum.map(plans, fn {device, addrs} -> {device.uid, addrs} end)
        )

      :execute ->
        {keys, aliases} = Enum.reduce(plans, {0, 0}, &purge(&1, &2, manifest, actor))
        Map.merge(base, %{purged_metadata_keys: keys, archived_alias_states: aliases})
    end
  end

  # One device's debris, one transaction. A half-applied device keeps working as
  # a mis-attribution: the metadata key alone still answers the mapper's
  # `Metadata["ip_alias:"<>ip]` probe, and the alias row alone still wins
  # find_device_uid_by_alias.
  defp purge({device, addresses}, {keys, aliases}, manifest, _actor) do
    {:ok, {key_count, alias_ids}} =
      Repo.transaction(fn ->
        {purge_metadata_keys(device.uid, addresses), archive_alias_states(device.uid, addresses)}
      end)

    record!(manifest, "purge_metadata_keys", "platform.ocsf_devices", [device.uid], %{
      addresses: addresses,
      keys: key_count
    })

    record!(manifest, "archive_alias_states", "platform.device_alias_states", alias_ids, %{
      device_id: device.uid,
      addresses: addresses
    })

    Logger.info(
      "netprobe-alias-debris: released #{length(addresses)} absorbed address(es) from #{device.uid}"
    )

    {keys + key_count, aliases + length(alias_ids)}
  end

  # The manifest IS the rollback evidence, so a write that fails must be loud.
  # `Manifest.record/6` returns the error rather than raising, and the ids are the
  # thing most likely to break it: a Postgres `uuid` arrives as a raw 16-byte
  # binary that Jason cannot encode, which is why the query casts to text.
  defp record!(manifest, action, table, ids, extra) do
    case Manifest.record(manifest, @step, action, table, ids, extra) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "netprobe-alias-debris: failed to record #{action} in the manifest: #{inspect(reason)}"
    end
  end

  # `- key` for each address. This cannot go through Device `:merge_metadata`:
  # jsonb `||` overwrites and inserts, it has no delete.
  defp purge_metadata_keys(uid, addresses) do
    keys = Enum.map(addresses, &("ip_alias:" <> &1))

    %{num_rows: rows} =
      query!(
        """
        UPDATE platform.ocsf_devices
        SET metadata = metadata - $2::text[],
            modified_time = timezone('utc', now())
        WHERE uid = $1
          AND metadata ?| $2::text[]
        """,
        [uid, keys]
      )

    if rows == 0, do: 0, else: length(keys)
  end

  # Archived, not stale. See the moduledoc: `:stale` is revivable and the mapper
  # still consults it, so marking stale would undo itself on the next discovery.
  defp archive_alias_states(uid, addresses) do
    %{rows: rows} =
      query!(
        """
        UPDATE platform.device_alias_states
        SET state = 'archived',
            updated_at = timezone('utc', now())
        WHERE device_id = $1
          AND alias_type = 'ip'
          AND alias_value = ANY($2)
          AND state <> 'archived'
        RETURNING id::text
        """,
        [uid, addresses]
      )

    List.flatten(rows)
  end

  # Devices that took a passive-netprobe update AND hold an ip_alias key for an
  # address that is not their own. Everything finer is decided by Decisions, so
  # the rule stays in one testable place -- this query only has to be a superset.
  defp candidates(opts) do
    limit = Keyword.get(opts, :netprobe_alias_limit, 500)

    %{rows: rows} =
      query!(
        """
        WITH candidate AS (
          SELECT d.uid, d.ip, d.metadata, d.discovery_sources,
                 ARRAY(
                   SELECT substring(k from 10)
                   FROM jsonb_object_keys(d.metadata) k
                   WHERE k LIKE 'ip_alias:%'
                     AND substring(k from 10) IS DISTINCT FROM d.ip
                 ) AS foreign_aliases
          FROM platform.ocsf_devices d
          WHERE d.deleted_at IS NULL
            AND jsonb_typeof(d.metadata) = 'object'
            AND 'passive-netprobe' = ANY(d.discovery_sources)
        )
        SELECT c.uid, c.ip, c.metadata, c.discovery_sources, c.foreign_aliases,
               ARRAY(
                 SELECT o.ip FROM platform.ocsf_devices o
                 WHERE o.ip = ANY(c.foreign_aliases) AND o.deleted_at IS NULL
               ) AS addresses_with_own_device
        FROM candidate c
        WHERE cardinality(c.foreign_aliases) > 0
        ORDER BY cardinality(c.foreign_aliases) DESC, c.uid
        LIMIT $1
        """,
        [limit]
      )

    Enum.map(rows, fn [uid, ip, metadata, sources, foreign, owned] ->
      %{
        uid: uid,
        ip: ip,
        metadata: metadata || %{},
        discovery_sources: sources || [],
        foreign_aliases: foreign || [],
        addresses_with_own_device: owned || []
      }
    end)
  end

  defp query!(sql, params), do: Repo.query!(sql, params)
end
