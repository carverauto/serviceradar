defmodule ServiceRadar.Inventory.Remediation.BroadcastAliasArchive do
  @moduledoc """
  Step `broadcast-alias-archive`.

  Archives identity (`:ip`) and `:interface_ip` alias rows whose value is an
  IPv4 broadcast address (`255.255.255.255` or the directed broadcast address of
  a subnet with prefix length `0..30`), strips leftover `ip_alias:<broadcast>`
  and `interface_ip_alias:<broadcast>` keys from `platform.ocsf_devices.metadata`,
  and removes broadcast addresses from `platform.discovered_interfaces.ip_addresses`.
  GitHub #5743.

  Values are judged as `AliasPolicy.broadcast_ip?/2` judges them: an explicit
  `/len` decides alone, and a bare address is checked against the device's
  known subnets. A `/24` inferred from a `.255` and sibling host pair on one
  interface is written to that interface's `ip_cidrs` metadata when the `.255`
  is removed, so the subnet stays known after its evidence is gone.

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
      SELECT device_uid AS device_id, NULL::text AS interface_uid, cidr AS cidr_text
      FROM #{schema}.virtualization_network_interfaces
      WHERE device_uid IS NOT NULL AND cidr IS NOT NULL AND btrim(cidr) <> ''
      UNION
      SELECT li.device_id, li.interface_uid, btrim(token) AS cidr_text
      FROM latest_ifaces li
      CROSS JOIN LATERAL unnest(li.ip_addresses) AS ip
      CROSS JOIN LATERAL regexp_split_to_table(ip, '[ ,]+') AS token
      WHERE token LIKE '%/%'
      UNION
      SELECT li.device_id, li.interface_uid, btrim(token) AS cidr_text
      FROM latest_ifaces li
      CROSS JOIN LATERAL (VALUES ('ip_cidrs'), ('cidr'), ('subnet')) AS k(name)
      CROSS JOIN LATERAL (
        SELECT li.metadata->>k.name AS val
        WHERE jsonb_typeof(li.metadata->k.name) = 'string'
        UNION ALL
        SELECT elem
        FROM jsonb_array_elements_text(
          CASE
            WHEN jsonb_typeof(li.metadata->k.name) = 'array' THEN li.metadata->k.name
            ELSE '[]'::jsonb
          END
        ) AS elem
      ) AS v
      CROSS JOIN LATERAL regexp_split_to_table(v.val, '[ ,]+') AS token
      WHERE token LIKE '%/%'
    ),
    explicit_cidrs AS (
      SELECT DISTINCT
        r.device_id,
        r.interface_uid,
        set_masklen(nv.addr, nv.prefix_len) AS net
      FROM raw_explicit_cidrs r
      CROSS JOIN LATERAL #{ipv4_value_sql("r.cidr_text")} AS nv
      WHERE nv.addr IS NOT NULL
        AND nv.prefix_len BETWEEN 0 AND 32
    ),
    iface_bare_ips AS (
      SELECT DISTINCT li.device_id, li.interface_uid, nv.addr
      FROM latest_ifaces li
      CROSS JOIN LATERAL unnest(li.ip_addresses) AS ip
      CROSS JOIN LATERAL #{ipv4_value_sql("ip")} AS nv
      WHERE nv.addr IS NOT NULL
        AND nv.prefix_len IS NULL
    ),
    inferred_pair_cidrs AS (
      SELECT DISTINCT
        b.device_id,
        b.interface_uid,
        network(set_masklen(b.addr, 24))::inet AS net
      FROM iface_bare_ips b
      WHERE split_part(host(b.addr), '.', 4) = '255'
        AND host(b.addr) <> '255.255.255.255'
        AND EXISTS (
          SELECT 1
          FROM iface_bare_ips h
          WHERE h.device_id = b.device_id
            AND h.interface_uid = b.interface_uid
            AND h.addr <<= network(set_masklen(b.addr, 24))
            AND split_part(host(h.addr), '.', 4)::int BETWEEN 1 AND 254
        )
        AND NOT EXISTS (
          SELECT 1
          FROM explicit_cidrs ec
          WHERE ec.device_id = b.device_id
            AND ec.interface_uid = b.interface_uid
            AND b.addr <<= network(ec.net)
        )
    ),
    device_broadcast_ips AS (
      SELECT DISTINCT
        c.device_id,
        host(broadcast(c.net)) AS bcast_ip
      FROM (
        SELECT device_id, net FROM explicit_cidrs WHERE masklen(net) <= 30
        UNION
        SELECT device_id, net FROM inferred_pair_cidrs
      ) c
    )
    """
  end

  # One row `(addr, prefix_len)` for a raw address value, parsed the way
  # `AliasPolicy` parses it: `%zone` dropped, an IPv4-mapped IPv6 address
  # unwrapped (its `/96..128` prefix shifted to `/0..32`), `addr` NULL when the
  # value is not IPv4, `prefix_len` NULL without a `/` and -1 when the prefix is
  # unusable.
  defp ipv4_value_sql(raw_value_expr) do
    """
    (
      SELECT
        CASE
          WHEN p.raw_addr IS NULL THEN NULL
          WHEN family(p.raw_addr) = 4 THEN p.raw_addr
          WHEN p.raw_addr <<= '::ffff:0:0/96'::inet
            THEN '0.0.0.0'::inet + (p.raw_addr - '::ffff:0.0.0.0'::inet)
        END AS addr,
        CASE
          WHEN p.prefix_text IS NULL THEN NULL
          WHEN p.raw_addr IS NULL OR btrim(p.prefix_text) !~ '^[0-9]{1,3}$' THEN -1
          WHEN btrim(p.prefix_text)::int <= 32 THEN btrim(p.prefix_text)::int
          WHEN family(p.raw_addr) = 6 AND btrim(p.prefix_text)::int BETWEEN 96 AND 128
            THEN btrim(p.prefix_text)::int - 96
          ELSE -1
        END AS prefix_len
      FROM (
        SELECT
          CASE
            WHEN btrim(split_part(v.value, '/', 1)) <> ''
              AND pg_input_is_valid(btrim(split_part(v.value, '/', 1)), 'inet')
              THEN btrim(split_part(v.value, '/', 1))::inet
          END AS raw_addr,
          CASE WHEN strpos(v.value, '/') > 0 THEN split_part(v.value, '/', 2) END AS prefix_text
        FROM (SELECT split_part(btrim(#{raw_value_expr}), '%', 1) AS value) v
      ) p
    )
    """
  end

  @doc false
  def alias_broadcast_predicate(device_id_expr, raw_value_expr) do
    """
    EXISTS (
      SELECT 1
      FROM #{ipv4_value_sql(raw_value_expr)} AS nv
      WHERE nv.addr IS NOT NULL
        AND (
          (
            host(nv.addr) = '255.255.255.255'
            AND (nv.prefix_len IS NULL OR nv.prefix_len >= 0)
          )
          OR (
            nv.prefix_len BETWEEN 0 AND 30
            AND host(nv.addr) = host(broadcast(set_masklen(nv.addr, nv.prefix_len)))
          )
          OR (
            nv.prefix_len IS NULL
            AND EXISTS (
              SELECT 1
              FROM device_broadcast_ips dbi
              WHERE dbi.device_id = #{device_id_expr}
                AND dbi.bcast_ip = host(nv.addr)
            )
          )
        )
    )
    """
  end

  @doc false
  def preserve_inferred_cidrs_sql(iface_expr) do
    """
    CASE
      WHEN (
        #{iface_expr}.metadata IS NULL
        OR (
          jsonb_typeof(#{iface_expr}.metadata) = 'object'
          AND NOT #{iface_expr}.metadata ? 'ip_cidrs'
        )
      )
      AND EXISTS (
        SELECT 1
        FROM inferred_pair_cidrs ipc
        WHERE ipc.device_id = #{iface_expr}.device_id
          AND ipc.interface_uid = #{iface_expr}.interface_uid
      )
      THEN COALESCE(#{iface_expr}.metadata, '{}'::jsonb) || jsonb_build_object(
        'ip_cidrs',
        (
          SELECT string_agg(DISTINCT ipc.net::text, ',' ORDER BY ipc.net::text)
          FROM inferred_pair_cidrs ipc
          WHERE ipc.device_id = #{iface_expr}.device_id
            AND ipc.interface_uid = #{iface_expr}.interface_uid
        )
      )
      ELSE #{iface_expr}.metadata
    END
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
        ),
        metadata = #{preserve_inferred_cidrs_sql("di")}
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
