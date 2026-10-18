defmodule ServiceRadar.Inventory.Remediation.BroadcastAliasArchive do
  @moduledoc """
  Step `broadcast-alias-archive`.

  Archives identity (`:ip`) and `:interface_ip` alias rows whose value is an
  IPv4 broadcast address (`255.255.255.255` or the directed broadcast address of
  a subnet with prefix length `0..30`), strips leftover `ip_alias:<broadcast>`
  and `interface_ip_alias:<broadcast>` keys from `platform.ocsf_devices.metadata`,
  and removes broadcast addresses from `platform.discovered_interfaces.ip_addresses`.
  GitHub #5743.

  Archives, does not mark stale: `:stale` is consulted by
  `MapperResultsIngestor.find_device_uid_by_alias/3` and revived on subsequent
  sightings.

  Deploy-time cleanup lives in
  `20261018150000_archive_broadcast_identity_aliases`. This step is the
  replayable sweeper.
  """

  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "broadcast-alias-archive"
  @default_limit 5_000
  @max_batches 10_000

  @ipv4_regex "^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?:/(?:3[0-2]|[12]?[0-9]))?$"
  @ipv4_cidr_regex "^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])/(?:3[0-2]|[12]?[0-9])$"
  @ipv4_255_regex "^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}255$"

  @doc false
  def broadcast_ctes(schema \\ "platform") do
    """
    WITH latest_ifaces AS (
      SELECT DISTINCT ON (device_id, interface_uid)
        device_id,
        interface_uid,
        COALESCE(ip_addresses, ARRAY[]::text[]) AS ip_addresses,
        COALESCE(metadata, '{}'::jsonb) AS metadata
      FROM #{schema}.discovered_interfaces
      ORDER BY device_id, interface_uid, timestamp DESC
    ),
    raw_explicit_cidrs AS (
      SELECT device_uid AS device_id, btrim(cidr) AS cidr_text
      FROM #{schema}.virtualization_network_interfaces
      WHERE device_uid IS NOT NULL AND cidr IS NOT NULL AND btrim(cidr) <> ''
      UNION
      SELECT li.device_id, btrim(ip) AS cidr_text
      FROM latest_ifaces li
      CROSS JOIN LATERAL unnest(li.ip_addresses) AS ip
      WHERE ip LIKE '%/%'
      UNION
      SELECT li.device_id, btrim(token) AS cidr_text
      FROM latest_ifaces li
      CROSS JOIN LATERAL regexp_split_to_table(
        concat_ws(
          ',',
          li.metadata->>'ip_cidrs',
          li.metadata->>'cidr',
          li.metadata->>'subnet'
        ),
        '\\s*,\\s*'
      ) AS token
      WHERE token LIKE '%/%'
    ),
    explicit_cidrs AS (
      SELECT DISTINCT device_id, cidr_text::inet AS net
      FROM raw_explicit_cidrs
      WHERE cidr_text ~ '#{@ipv4_cidr_regex}'
        AND family(cidr_text::inet) = 4
    ),
    inferred_pair_cidrs AS (
      SELECT DISTINCT
        li.device_id,
        set_masklen((btrim(bcast_ip)::inet), 24) AS net
      FROM latest_ifaces li
      CROSS JOIN LATERAL unnest(li.ip_addresses) AS bcast_ip
      CROSS JOIN LATERAL unnest(li.ip_addresses) AS host_ip
      WHERE btrim(bcast_ip) ~ '#{@ipv4_255_regex}'
        AND btrim(bcast_ip) <> '255.255.255.255'
        AND btrim(host_ip) ~ '#{@ipv4_regex}'
        AND btrim(host_ip) NOT LIKE '%/%'
        AND btrim(host_ip) <> btrim(bcast_ip)
        AND NOT (btrim(host_ip) ~ '\\.(0|255)$')
        AND network(set_masklen((btrim(bcast_ip)::inet), 24)) =
            network(set_masklen((btrim(host_ip)::inet), 24))
        AND NOT EXISTS (
          SELECT 1
          FROM explicit_cidrs ec
          WHERE ec.device_id = li.device_id
            AND (btrim(bcast_ip)::inet) <<= ec.net
        )
    ),
    device_broadcast_ips AS (
      SELECT DISTINCT
        c.device_id,
        host(broadcast(c.net)) AS bcast_ip
      FROM (
        SELECT device_id, net FROM explicit_cidrs WHERE masklen(net) BETWEEN 0 AND 30
        UNION
        SELECT device_id, net FROM inferred_pair_cidrs
      ) c
    )
    """
  end

  @doc false
  def run(mode, opts, manifest, _actor) do
    would_archive = candidate_count()
    would_strip = metadata_device_count()
    would_strip_ifaces = discovered_interface_count()

    base = %{
      examined_aliases: would_archive,
      would_archive: would_archive,
      would_strip_metadata_devices: would_strip,
      would_strip_discovered_interfaces: would_strip_ifaces
    }

    case mode do
      :dry_run ->
        base

      :execute ->
        archived = archive_all(opts, manifest)
        stripped = strip_metadata(manifest)
        stripped_ifaces = strip_discovered_interfaces(manifest)

        Map.merge(base, %{
          archived_alias_states: length(archived),
          stripped_metadata_devices: stripped,
          stripped_discovered_interfaces: stripped_ifaces
        })
    end
  end

  defp candidate_count do
    %{rows: [[count]]} =
      query!(
        """
        #{broadcast_ctes()}
        SELECT count(*)::int
        FROM platform.device_alias_states das
        WHERE das.alias_type IN ('ip', 'interface_ip')
          AND das.state <> 'archived'
          AND #{alias_broadcast_predicate("das.device_id", "das.alias_value")}
        """,
        []
      )

    count
  end

  defp metadata_device_count do
    %{rows: [[count]]} =
      query!(
        """
        #{broadcast_ctes()}
        SELECT count(*)::int
        FROM platform.ocsf_devices d
        WHERE jsonb_typeof(d.metadata) = 'object'
          AND EXISTS (
            SELECT 1
            FROM jsonb_object_keys(d.metadata) AS key
            WHERE (
              key LIKE 'ip_alias:%'
              AND #{alias_broadcast_predicate("d.uid", "substring(key from 10)")}
            ) OR (
              key LIKE 'interface_ip_alias:%'
              AND #{alias_broadcast_predicate("d.uid", "substring(key from 20)")}
            )
          )
        """,
        []
      )

    count
  end

  defp discovered_interface_count do
    %{rows: [[count]]} =
      query!(
        """
        #{broadcast_ctes()}
        SELECT count(*)::int
        FROM platform.discovered_interfaces di
        WHERE COALESCE(array_length(di.ip_addresses, 1), 0) > 0
          AND EXISTS (
            SELECT 1
            FROM unnest(di.ip_addresses) AS ip
            WHERE #{alias_broadcast_predicate("di.device_id", "ip")}
          )
        """,
        []
      )

    count
  end

  defp archive_all(opts, manifest) do
    limit = Keyword.get(opts, :broadcast_alias_limit, @default_limit)

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
        #{broadcast_ctes()}
        SELECT das.id::text
        FROM platform.device_alias_states das
        WHERE das.alias_type IN ('ip', 'interface_ip')
          AND das.state <> 'archived'
          AND #{alias_broadcast_predicate("das.device_id", "das.alias_value")}
        ORDER BY das.device_id, das.alias_value
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

    Logger.info("broadcast-alias-archive: archived #{length(archived)} identity alias row(s)")

    archived
  end

  defp strip_metadata(manifest) do
    %{rows: rows} =
      query!(
        """
        #{broadcast_ctes()}
        UPDATE platform.ocsf_devices AS d
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
                AND #{alias_broadcast_predicate("d_inner.uid", "substring(key from 10)")}
              ) OR (
                key LIKE 'interface_ip_alias:%'
                AND #{alias_broadcast_predicate("d_inner.uid", "substring(key from 20)")}
              )
            ) AS keys
          FROM platform.ocsf_devices d_inner
          WHERE jsonb_typeof(d_inner.metadata) = 'object'
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
        "broadcast-alias-archive: stripped broadcast ip_alias keys from #{length(uids)} device(s)"
      )
    end

    length(uids)
  end

  defp strip_discovered_interfaces(manifest) do
    %{rows: rows} =
      query!(
        """
        #{broadcast_ctes()}
        UPDATE platform.discovered_interfaces AS di
        SET ip_addresses = ARRAY(
          SELECT ip
          FROM unnest(di.ip_addresses) AS ip
          WHERE NOT (#{alias_broadcast_predicate("di.device_id", "ip")})
        )
        WHERE COALESCE(array_length(di.ip_addresses, 1), 0) > 0
          AND EXISTS (
            SELECT 1
            FROM unnest(di.ip_addresses) AS ip
            WHERE #{alias_broadcast_predicate("di.device_id", "ip")}
          )
        RETURNING di.device_id || ':' || di.interface_uid
        """,
        []
      )

    keys = rows |> List.flatten() |> Enum.uniq()

    if keys != [] do
      record!(
        manifest,
        "strip_discovered_interface_broadcast_ips",
        "platform.discovered_interfaces",
        keys,
        %{count: length(keys)}
      )

      Logger.info(
        "broadcast-alias-archive: stripped broadcast ip_addresses from #{length(keys)} interface(s)"
      )
    end

    length(keys)
  end

  @doc false
  def alias_broadcast_predicate(device_id_expr, raw_value_expr) do
    trimmed = "split_part(btrim(#{raw_value_expr}), '%', 1)"

    """
    (
      #{trimmed} = '255.255.255.255'
      OR (
        #{trimmed} ~ '#{@ipv4_cidr_regex}'
        AND masklen((#{trimmed})::inet) BETWEEN 0 AND 30
        AND host((#{trimmed})::inet) = host(broadcast((#{trimmed})::inet))
      )
      OR (
        #{trimmed} ~ '#{@ipv4_regex}'
        AND NOT (
          #{trimmed} LIKE '%/%'
          AND masklen((#{trimmed})::inet) IN (31, 32)
        )
        AND EXISTS (
          SELECT 1
          FROM device_broadcast_ips dbi
          WHERE dbi.device_id = #{device_id_expr}
            AND dbi.bcast_ip = split_part(#{trimmed}, '/', 1)
        )
      )
    )
    """
  end

  defp record!(manifest, action, table, ids, extra) do
    case Manifest.record(manifest, @step, action, table, ids, extra) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "broadcast-alias-archive: failed to record #{action} in the manifest: #{inspect(reason)}"
    end
  end

  defp query!(sql, params), do: Repo.query!(sql, params)
end
