defmodule ServiceRadar.Inventory.Remediation.LinkLocalAliasArchive do
  @moduledoc """
  Step `link-local-alias-archive`.

  Archives identity (`:ip`) and `:interface_ip` alias rows whose value is
  link-local (`fe80::/10` or `169.254/16`), and strips leftover
  `ip_alias:fe80::…` / `ip_alias:169.254.…` metadata keys. Those addresses
  are unique per link, not globally, so "these two devices share an address"
  is not merge evidence. GitHub #4022.

  Archives, does not mark stale. `:stale` is still consulted by
  `MapperResultsIngestor.find_device_uid_by_alias/3` and
  `maybe_reactivate_alias/2` REVIVES it. Alias debris in this system
  self-revives (GitHub #3971/#3976/#3979); a cleanup that left these stale
  would undo itself on the next discovery.

  Classification uses `platform.sr_address_rank` (rank 20 = link-local),
  which already strips `%zone` and `/cidr` the way collectors send them.

  Deploy-time cleanup lives in
  `20260825031000_archive_link_local_identity_aliases`. This step is the
  replayable sweeper. Execute loops until a batch is empty so a fleet with
  more than one LIMIT of leftover rows is still fully archived.
  """

  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "link-local-alias-archive"
  @default_limit 5_000
  @max_batches 10_000

  @doc false
  def run(mode, opts, manifest, _actor) do
    would_archive = candidate_count()
    would_strip = metadata_device_count()

    base = %{
      examined_aliases: would_archive,
      would_archive: would_archive,
      would_strip_metadata_devices: would_strip
    }

    case mode do
      :dry_run ->
        base

      :execute ->
        archived = archive_all(opts, manifest)
        stripped = strip_metadata(manifest)

        Map.merge(base, %{
          archived_alias_states: length(archived),
          stripped_metadata_devices: stripped
        })
    end
  end

  defp candidate_count do
    %{rows: [[count]]} =
      query!(
        """
        SELECT count(*)::int
        FROM platform.device_alias_states
        WHERE alias_type IN ('ip', 'interface_ip')
          AND state <> 'archived'
          AND platform.sr_address_rank(alias_value) = 20
        """,
        []
      )

    count
  end

  defp metadata_device_count do
    %{rows: [[count]]} =
      query!(
        """
        SELECT count(*)::int
        FROM platform.ocsf_devices d
        WHERE jsonb_typeof(d.metadata) = 'object'
          AND EXISTS (
            SELECT 1
            FROM jsonb_object_keys(d.metadata) AS key
            WHERE key LIKE 'ip_alias:%'
              AND platform.sr_address_rank(substring(key from 10)) = 20
          )
        """,
        []
      )

    count
  end

  defp archive_all(opts, manifest) do
    limit = Keyword.get(opts, :link_local_alias_limit, @default_limit)

    Enum.reduce_while(1..@max_batches, [], fn _batch, acc ->
      ids = candidate_ids(limit)

      case archive(ids, manifest) do
        [] -> {:halt, acc}
        archived -> {:cont, acc ++ archived}
      end
    end)
  end

  defp candidate_ids(limit) do
    %{rows: rows} =
      query!(
        """
        SELECT id::text
        FROM platform.device_alias_states
        WHERE alias_type IN ('ip', 'interface_ip')
          AND state <> 'archived'
          AND platform.sr_address_rank(alias_value) = 20
        ORDER BY device_id, alias_value
        LIMIT $1
        """,
        [limit]
      )

    List.flatten(rows)
  end

  defp archive([], _manifest), do: []

  defp archive(ids, manifest) do
    %{rows: rows} =
      query!(
        """
        UPDATE platform.device_alias_states
        SET state = 'archived',
            updated_at = timezone('utc', now())
        WHERE id::text = ANY($1::text[])
          AND state <> 'archived'
        RETURNING id::text
        """,
        [ids]
      )

    archived = List.flatten(rows)

    record!(manifest, "archive_alias_states", "platform.device_alias_states", archived, %{
      count: length(archived)
    })

    Logger.info("link-local-alias-archive: archived #{length(archived)} identity alias row(s)")

    archived
  end

  defp strip_metadata(manifest) do
    %{rows: rows} =
      query!(
        """
        UPDATE platform.ocsf_devices AS d
        SET metadata = d.metadata - k.keys,
            modified_time = timezone('utc', now())
        FROM (
          SELECT
            uid,
            ARRAY(
              SELECT key
              FROM jsonb_object_keys(metadata) AS key
              WHERE key LIKE 'ip_alias:%'
                AND platform.sr_address_rank(substring(key from 10)) = 20
            ) AS keys
          FROM platform.ocsf_devices
          WHERE jsonb_typeof(metadata) = 'object'
        ) AS k
        WHERE d.uid = k.uid
          AND cardinality(k.keys) > 0
        RETURNING d.uid
        """,
        []
      )

    uids = List.flatten(rows)

    if uids != [] do
      record!(manifest, "strip_ip_alias_metadata", "platform.ocsf_devices", uids, %{
        count: length(uids)
      })

      Logger.info(
        "link-local-alias-archive: stripped link-local ip_alias keys from #{length(uids)} device(s)"
      )
    end

    length(uids)
  end

  defp record!(manifest, action, table, ids, extra) do
    case Manifest.record(manifest, @step, action, table, ids, extra) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "link-local-alias-archive: failed to record #{action} in the manifest: #{inspect(reason)}"
    end
  end

  defp query!(sql, params), do: Repo.query!(sql, params)
end
