defmodule ServiceRadar.Inventory.Remediation.LinkLocalAliasArchive do
  @moduledoc """
  Step `link-local-alias-archive`.

  Archives identity (`:ip`) alias rows whose value is link-local
  (`fe80::/10` or `169.254/16`). Those addresses are unique per link, not
  globally, so "these two devices share an address" is not merge evidence.
  GitHub #4022.

  Archives, does not mark stale. `:stale` is still consulted by
  `MapperResultsIngestor.find_device_uid_by_alias/3` and
  `maybe_reactivate_alias/2` REVIVES it. Alias debris in this system
  self-revives (GitHub #3971/#3976/#3979); a cleanup that left these stale
  would undo itself on the next discovery.

  Classification uses `platform.sr_address_rank` (rank 20 = link-local),
  which already strips `%zone` and `/cidr` the way collectors send them.
  """

  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "link-local-alias-archive"

  @doc false
  def run(mode, opts, manifest, _actor) do
    ids = candidate_ids(opts)

    base = %{
      examined_aliases: length(ids),
      would_archive: length(ids)
    }

    case mode do
      :dry_run ->
        base

      :execute ->
        archived = archive(ids, manifest)
        Map.put(base, :archived_alias_states, length(archived))
    end
  end

  defp candidate_ids(opts) do
    limit = Keyword.get(opts, :link_local_alias_limit, 5_000)

    %{rows: rows} =
      query!(
        """
        SELECT id::text
        FROM platform.device_alias_states
        WHERE alias_type = 'ip'
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
