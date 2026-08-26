defmodule ServiceRadar.Identity.DeviceLookup do
  @moduledoc """
  Device identity lookup service.

  Provides the GetCanonicalDevice API, ported from Go core's identity_lookup.go.
  This module resolves identity keys (MAC, IP, Armis ID, etc.) to canonical
  device records.

  ## Identity Key Kinds

  - `:device_id` - Direct ServiceRadar device ID lookup
  - `:partition_ip` - Partition-scoped IP lookup (format: "partition:ip")
  - `:ip` - IP address lookup (may match multiple devices)
  - `:mac` - MAC address lookup
  - `:armis_id` - Armis platform device ID
  - `:netbox_id` - NetBox device ID

  ## Usage

      # Single key lookup
      {:ok, result} = DeviceLookup.get_canonical_device([
        %{kind: :mac, value: "AA:BB:CC:DD:EE:FF"}
      ])

      # Multiple keys with fallback
      {:ok, result} = DeviceLookup.get_canonical_device([
        %{kind: :mac, value: "AA:BB:CC:DD:EE:FF"},
        %{kind: :ip, value: "192.168.1.100"}
      ], ip_hint: "192.168.1.100")

  ## Cache Policy

  The identity cache is an explicit read optimization. Callers that create,
  update, restore, delete, promote, suppress, or otherwise mutate inventory
  must use the default cache-bypassing behavior. Read-only enrichment paths may
  opt in with `use_cache: true` after verifying stale identity cannot affect a
  write decision.

  Current caller classification:

  - Sweep result ingestion and sweep event-writer availability updates:
    authoritative lookup, `use_cache: false`.
  - Core result processing that prepares device updates: authoritative lookup,
    `use_cache: false`.
  - ICMP and SNMP metric ingestion: authoritative lookup before writing
    timeseries rows, `use_cache: false`.
  - Direct `IdentityCache` access: limited to the cache implementation and
    tests.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Identity.AliasPolicy
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @type identity_kind ::
          :device_id
          | :partition_ip
          | :ip
          | :mac
          | :armis_id
          | :netbox_id
          | :integration_id

  @type identity_key :: %{
          kind: identity_kind(),
          value: String.t()
        }

  @type canonical_record :: %{
          canonical_device_id: String.t(),
          partition: String.t(),
          metadata_hash: String.t() | nil,
          attributes: map(),
          updated_at: DateTime.t()
        }

  @type lookup_result :: %{
          found: boolean(),
          record: canonical_record() | nil,
          matched_key: identity_key() | nil,
          resolved_via: String.t()
        }

  @kind_map %{
    :device_id => :device_id,
    :partition_ip => :partition_ip,
    :ip => :ip,
    :mac => :mac,
    :armis_id => :armis_id,
    :netbox_id => :netbox_id,
    :integration_id => :integration_id,
    "device_id" => :device_id,
    "partition_ip" => :partition_ip,
    "ip" => :ip,
    "mac" => :mac,
    "armis_id" => :armis_id,
    "netbox_id" => :netbox_id,
    "integration_id" => :integration_id
  }

  @identifier_type_map %{
    :armis_id => :armis_device_id,
    :netbox_id => :netbox_device_id,
    :integration_id => :integration_id
  }

  @doc """
  Resolve identity keys to a canonical device record.

  Tries each key in order until a match is found. Returns the first match
  with information about which key was used.

  ## Options

  - `:ip_hint` - Optional IP to append as a fallback key
  - `:partition` - Partition context for partition-scoped lookups
  - `:use_cache` - Whether to use the identity cache (default: false)
  - `:actor` - Actor for authorization context
  """
  @spec get_canonical_device([identity_key()], keyword()) ::
          {:ok, lookup_result()} | {:error, term()}
  def get_canonical_device(identity_keys, opts \\ []) do
    start_time = System.monotonic_time(:microsecond)

    keys = normalize_identity_keys(identity_keys, opts)

    if Enum.empty?(keys) do
      {:ok, %{found: false, record: nil, matched_key: nil, resolved_via: "empty_keys"}}
    else
      result = do_lookup(keys, opts)
      emit_lookup_telemetry(result, start_time)
      {:ok, result}
    end
  end

  @doc """
  Batch lookup for multiple IPs.

  Optimized for sweep result processing - looks up canonical identities
  for a list of IPs in bulk.

  ## Options

  - `:use_cache` - Whether to use identity cache (default: false)
  - `:actor` - Actor for authorization context
  - `:include_detected` - Also check detected aliases as fallback (default: false)
  """
  @spec batch_lookup_by_ip([String.t()], keyword()) :: %{String.t() => canonical_record()}
  def batch_lookup_by_ip(ips, opts \\ []) when is_list(ips) do
    use_cache = Keyword.get(opts, :use_cache, false)
    actor = Keyword.get(opts, :actor)
    include_detected = Keyword.get(opts, :include_detected, false)
    include_deleted = Keyword.get(opts, :include_deleted, false)

    unique_ips =
      ips
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    partition = lookup_partition(opts)

    if Enum.empty?(unique_ips) do
      %{}
    else
      # First lookup confirmed/updated aliases
      alias_results =
        lookup_aliases_by_ip(
          unique_ips,
          opts
          |> Keyword.put(:include_deleted, include_deleted)
          |> Keyword.put(:partition, partition)
        )

      remaining_ips = unique_ips -- Map.keys(alias_results)

      {cache_hits, cache_misses} = fetch_cache_hits(remaining_ips, use_cache, partition)
      db_results = lookup_devices_by_ips(cache_misses, actor, include_deleted, partition)

      cache_db_results(alias_results, use_cache)
      cache_db_results(db_results, use_cache)

      primary_results =
        cache_hits
        |> Map.merge(alias_results, fn _key, _cached, alias_record -> alias_record end)
        |> Map.merge(db_results, fn _key, existing, _db_record -> existing end)

      # If include_detected is true, check detected aliases for remaining IPs
      if include_detected do
        still_unknown = unique_ips -- Map.keys(primary_results)

        detected_results =
          lookup_detected_aliases_by_ip(
            still_unknown,
            Keyword.put(opts, :include_deleted, include_deleted)
          )

        Map.merge(primary_results, detected_results)
      else
        primary_results
      end
    end
  end

  @doc """
  Lookup detected (not yet confirmed) aliases for a list of IPs.

  Used as fallback when no confirmed alias or device exists.
  Returns both the device record and the alias state for potential confirmation.
  """
  @spec lookup_detected_aliases_by_ip([String.t()], keyword()) ::
          %{String.t() => {canonical_record(), DeviceAliasState.t()}}
  def lookup_detected_aliases_by_ip([], _opts), do: %{}

  def lookup_detected_aliases_by_ip(ips, opts) do
    lookup_alias_state_map(
      ips,
      opts,
      &read_detected_alias_states/3,
      &build_detected_alias_map/2,
      "Detected alias lookup failed"
    )
  end

  # The cache is keyed on IP alone, but the live unique index is
  # (partition, ip): the same address can exist in a monitoring partition and
  # in an isolation partition as two DIFFERENT devices. A cached record from
  # another partition is therefore not an answer to this question -- treat it
  # as a MISS so the lookup falls through to the partition-scoped DB query.
  #
  # Deliberately NOT re-keyed on {partition, ip}. Four invalidation sites
  # (device_notifier, device_identifier_notifier, device_alias_state_notifier
  # and sync/state_events) call IdentityCache.delete/1 with a bare IP, so
  # changing the key format would silently turn every one of them into a
  # no-op and strand stale entries forever -- a worse bug than this one.
  defp fetch_cache_hits(unique_ips, true, partition) do
    {hits, misses} = IdentityCache.get_batch(unique_ips)

    {matching, mismatched} =
      Enum.split_with(hits, fn {_ip, record} -> record_partition?(record, partition) end)

    misses = misses ++ Enum.map(mismatched, fn {ip, _record} -> ip end)

    emit_authoritative_fallback_telemetry(length(misses), :cache_miss)
    {Map.new(matching), misses}
  end

  defp fetch_cache_hits(unique_ips, false, _partition), do: {%{}, unique_ips}

  defp record_partition?(%{partition: value}, partition) when is_binary(value) and value != "",
    do: value == partition

  # A record cached without a usable partition predates partitioning; only the
  # default partition may claim it. Mirrors device_partition/1's fallback.
  defp record_partition?(_record, partition), do: partition == "default"

  defp cache_db_results(db_results, true) do
    Enum.each(db_results, fn {ip, record} ->
      IdentityCache.put(ip, record)
    end)
  end

  defp cache_db_results(_db_results, false), do: :ok

  # Private functions

  defp normalize_identity_keys(keys, opts) do
    {normalized, _seen_set} =
      Enum.reduce(keys, {[], MapSet.new()}, fn key, {acc, seen_set} ->
        case normalize_key_entry(key, seen_set) do
          {:skip, seen_set} -> {acc, seen_set}
          {:ok, normalized_key, seen_set} -> {[normalized_key | acc], seen_set}
        end
      end)

    normalized
    |> Enum.reverse()
    |> maybe_add_ip_hint(opts)
  end

  defp normalize_key_entry(key, seen_set) do
    kind = normalize_kind(key[:kind] || key["kind"])
    value = String.trim(to_string(key[:value] || key["value"] || ""))

    cond do
      kind == :unspecified or value == "" ->
        {:skip, seen_set}

      MapSet.member?(seen_set, "#{kind}|#{value}") ->
        {:skip, seen_set}

      true ->
        normalized_key = %{kind: kind, value: value}
        {:ok, normalized_key, MapSet.put(seen_set, "#{kind}|#{value}")}
    end
  end

  defp maybe_add_ip_hint(normalized, opts) do
    case Keyword.get(opts, :ip_hint) do
      nil ->
        normalized

      ip_hint ->
        ip = String.trim(ip_hint)
        signature = "ip|#{ip}"
        seen = MapSet.new(normalized, &"#{&1.kind}|#{&1.value}")

        if ip != "" and not MapSet.member?(seen, signature) do
          normalized ++ [%{kind: :ip, value: ip}]
        else
          normalized
        end
    end
  end

  defp normalize_kind(kind), do: Map.get(@kind_map, kind, :unspecified)

  defp do_lookup(keys, opts) do
    use_cache = Keyword.get(opts, :use_cache, false)
    actor = Keyword.get(opts, :actor)
    include_deleted = Keyword.get(opts, :include_deleted, false)
    partition = lookup_partition(opts)

    Enum.reduce_while(
      keys,
      %{found: false, record: nil, matched_key: nil, resolved_via: "miss"},
      fn key, _acc ->
        case cached_record_for_key(key, use_cache, partition) do
          {:ok, record} ->
            {:halt, %{found: true, record: record, matched_key: key, resolved_via: "cache"}}

          :miss ->
            handle_lookup_miss(key, actor, include_deleted, use_cache, partition)
        end
      end
    )
  end

  defp cached_record_for_key(%{kind: :ip, value: value}, true, partition) do
    case IdentityCache.get(value) do
      nil ->
        :miss

      record ->
        # Same cross-partition guard as fetch_cache_hits/3.
        if record_partition?(record, partition), do: {:ok, record}, else: :miss
    end
  end

  defp cached_record_for_key(_key, _use_cache, _partition), do: :miss

  defp handle_lookup_miss(key, actor, include_deleted, use_cache, partition) do
    case lookup_by_key(key, actor, include_deleted, partition) do
      {:ok, nil} ->
        {:cont, %{found: false, record: nil, matched_key: nil, resolved_via: "miss"}}

      {:ok, device} ->
        record = build_record_from_device(device)
        cache_lookup_result(key, record, use_cache)
        {:halt, %{found: true, record: record, matched_key: key, resolved_via: "db"}}

      {:error, reason} ->
        Logger.debug("Identity lookup failed for #{key.kind}:#{key.value}: #{inspect(reason)}")

        {:cont, %{found: false, record: nil, matched_key: nil, resolved_via: "error"}}
    end
  end

  defp cache_lookup_result(%{kind: :ip, value: value}, record, true) do
    IdentityCache.put(value, record)
  end

  defp cache_lookup_result(_key, _record, _use_cache), do: :ok

  defp lookup_by_key(%{kind: :device_id, value: device_id}, actor, include_deleted, _partition) do
    Device
    |> Ash.Query.for_read(:by_uid, %{uid: device_id, include_deleted: include_deleted})
    |> read_one_with_actor(actor)
  end

  defp lookup_by_key(%{kind: :partition_ip, value: value}, actor, include_deleted, _partition) do
    {partition, ip} = split_partition_ip(value)
    lookup_by_key(%{kind: :ip, value: ip}, actor, include_deleted, partition)
  end

  defp lookup_by_key(%{kind: :ip, value: ip}, actor, include_deleted, partition) do
    case lookup_alias_device_by_ip(ip, actor,
           include_deleted: include_deleted,
           partition: partition
         ) do
      {:ok, %Device{} = device} ->
        {:ok, device}

      _ ->
        Device
        |> Ash.Query.for_read(:by_ip, %{
          ip: ip,
          partition: partition,
          include_deleted: include_deleted
        })
        |> read_canonical_device(actor, include_deleted)
    end
  end

  defp lookup_by_key(%{kind: :mac, value: mac}, actor, include_deleted, _partition) do
    normalized_mac = normalize_mac(mac)

    Device
    |> Ash.Query.for_read(:by_mac, %{mac: normalized_mac, include_deleted: include_deleted})
    |> read_canonical_device(actor, include_deleted)
  end

  defp lookup_by_key(%{kind: id_type, value: id_value}, actor, include_deleted, partition)
       when id_type in [:armis_id, :netbox_id, :integration_id] do
    DeviceIdentifier
    |> Ash.Query.for_read(:lookup, %{
      identifier_type: Map.fetch!(@identifier_type_map, id_type),
      identifier_value: id_value,
      partition: partition
    })
    |> read_with_actor(actor)
    |> case do
      {:ok, [identifier | _]} ->
        Device
        |> Ash.Query.for_read(:by_uid, %{
          uid: identifier.device_id,
          include_deleted: include_deleted
        })
        |> read_one_with_actor(actor)

      {:ok, []} ->
        {:ok, nil}

      error ->
        error
    end
  end

  defp lookup_by_key(_key, _actor, _include_deleted, _partition), do: {:ok, nil}

  defp lookup_devices_by_ips([], _actor, _include_deleted, _partition), do: %{}

  defp lookup_devices_by_ips(ips, actor, include_deleted, partition) do
    # Batch query for all IPs in one partition. The live unique index is
    # (partition, ip); looking up by IP alone would pick the isolation copy
    # when a monitoring partition also has the address.
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: include_deleted})
    |> Ash.Query.filter(ip in ^ips and partition == ^partition)
    |> read_page_with_actor(actor)
    |> case do
      {:ok, devices} ->
        ash_results =
          devices
          |> Enum.group_by(& &1.ip)
          |> Enum.flat_map(fn {ip, grouped_devices} ->
            grouped_devices
            |> select_canonical_device(include_deleted)
            |> maybe_record_for_ip(ip)
          end)
          |> Map.new()

        missing_ips = ips -- Map.keys(ash_results)

        Map.merge(
          ash_results,
          lookup_devices_by_ips_sql(missing_ips, include_deleted, actor, partition),
          fn _ip, ash_record, _sql_record -> ash_record end
        )

      {:error, reason} ->
        Logger.debug("Batch device lookup by IP failed, using SQL fallback: #{inspect(reason)}")
        lookup_devices_by_ips_sql(ips, include_deleted, actor, partition)
    end
  end

  defp lookup_devices_by_ips_sql([], _include_deleted, _actor, _partition), do: %{}

  defp lookup_devices_by_ips_sql(ips, include_deleted, actor, partition) do
    if SystemActor.system_actor?(actor) do
      do_lookup_devices_by_ips_sql(ips, include_deleted, partition)
    else
      %{}
    end
  end

  defp do_lookup_devices_by_ips_sql(ips, include_deleted, partition) do
    sql = """
    SELECT uid, ip, hostname, metadata, partition
    FROM ocsf_devices
    WHERE ip = ANY($1)
      AND ($2 OR deleted_at IS NULL)
      AND partition = $3
    ORDER BY
      ip ASC,
      CASE WHEN COALESCE(metadata, '{}'::jsonb) ? '_merged_into' THEN 1 ELSE 0 END ASC,
      CASE WHEN lower(COALESCE(metadata->>'_deleted', '')) = 'true' THEN 1 ELSE 0 END ASC,
      is_active DESC,
      modified_time DESC NULLS LAST,
      created_time DESC NULLS LAST,
      uid ASC
    """

    case Repo.query(sql, [ips, include_deleted, partition]) do
      {:ok, %{columns: columns, rows: rows}} ->
        rows
        |> Enum.map(&row_to_map(columns, &1))
        |> Enum.group_by(& &1["ip"])
        |> Enum.flat_map(fn {ip, grouped_rows} ->
          grouped_rows
          |> select_canonical_row()
          |> maybe_record_for_ip_row(ip)
        end)
        |> Map.new()

      {:error, reason} ->
        Logger.debug("SQL fallback device lookup by IP failed: #{inspect(reason)}")
        %{}
    end
  end

  defp row_to_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new()
  end

  defp select_canonical_row([]), do: nil

  defp select_canonical_row(rows) do
    Enum.find(rows, fn row ->
      metadata = row["metadata"] || %{}

      not Map.has_key?(metadata, "_merged_into") and
        String.downcase(to_string(metadata["_deleted"] || "")) != "true"
    end) || List.first(rows)
  end

  defp lookup_aliases_by_ip([], _opts), do: %{}

  defp lookup_aliases_by_ip(ips, opts) do
    lookup_alias_state_map(
      ips,
      opts,
      &read_alias_states/3,
      &build_alias_map/2,
      "Alias lookup failed"
    )
  end

  defp lookup_alias_state_map(ips, opts, reader, builder, error_message) do
    actor = Keyword.get(opts, :actor)
    partition = Keyword.get(opts, :partition)
    include_deleted = Keyword.get(opts, :include_deleted, false)

    case reader.(ips, partition, actor) do
      {:ok, []} ->
        %{}

      {:ok, aliases} ->
        aliases
        |> load_alias_devices(actor, include_deleted)
        |> builder.(aliases)

      {:error, _} ->
        %{}
    end
  rescue
    e ->
      Logger.warning("#{error_message}: #{inspect(e)}")
      %{}
  end

  defp read_alias_states(ips, partition, actor) do
    case Enum.filter(ips, &AliasPolicy.valid_alias_ip?/1) do
      [] ->
        {:ok, []}

      ips ->
        DeviceAliasState
        |> Ash.Query.filter(
          alias_type == :ip and alias_value in ^ips and state in [:confirmed, :updated]
        )
        |> maybe_filter_alias_partition(partition)
        |> read_with_actor(actor)
    end
  end

  defp read_detected_alias_states(ips, partition, actor) do
    case Enum.filter(ips, &AliasPolicy.valid_alias_ip?/1) do
      [] ->
        {:ok, []}

      ips ->
        DeviceAliasState
        |> Ash.Query.filter(alias_type == :ip and alias_value in ^ips and state == :detected)
        |> maybe_filter_alias_partition(partition)
        # Prefer aliases with more sightings (closer to confirmation)
        |> Ash.Query.sort(sighting_count: :desc, first_seen_at: :asc)
        |> read_with_actor(actor)
    end
  end

  defp build_detected_alias_map(devices, aliases) do
    # Group by IP value, take the first (highest sighting_count, earliest first_seen)
    aliases
    |> Enum.group_by(& &1.alias_value)
    |> Enum.reduce(%{}, fn {ip, ip_aliases}, acc ->
      # Take the alias with most sightings
      best_alias = List.first(ip_aliases)

      case Map.get(devices, best_alias.device_id) do
        nil ->
          acc

        device ->
          record = build_record_from_device(device)
          Map.put(acc, ip, {record, best_alias})
      end
    end)
  end

  defp load_alias_devices(aliases, actor, include_deleted) do
    device_ids = aliases |> Enum.map(& &1.device_id) |> Enum.uniq()

    case device_ids do
      [] ->
        %{}

      _ ->
        Device
        |> Ash.Query.for_read(:read, %{include_deleted: include_deleted})
        |> Ash.Query.filter(uid in ^device_ids)
        |> read_page_with_actor(actor)
        |> case do
          {:ok, records} -> Map.new(records, &{&1.uid, &1})
          _ -> %{}
        end
    end
  end

  defp build_alias_map(devices, aliases) do
    Enum.reduce(aliases, %{}, fn alias_state, acc ->
      case Map.get(devices, alias_state.device_id) do
        nil -> acc
        device -> Map.put(acc, alias_state.alias_value, build_record_from_device(device))
      end
    end)
  end

  defp lookup_alias_device_by_ip(ip, actor, opts) do
    partition = Keyword.get(opts, :partition)
    include_deleted = Keyword.get(opts, :include_deleted, false)

    query =
      DeviceAliasState
      |> Ash.Query.filter(
        alias_type == :ip and alias_value == ^ip and state in [:confirmed, :updated]
      )
      |> maybe_filter_alias_partition(partition)

    case read_with_actor(query, actor) do
      {:ok, [%DeviceAliasState{device_id: device_id} | _]} ->
        Device
        |> Ash.Query.for_read(:by_uid, %{uid: device_id, include_deleted: include_deleted})
        |> read_one_with_actor(actor)

      {:ok, []} ->
        {:ok, nil}

      error ->
        error
    end
  end

  defp maybe_filter_alias_partition(query, nil), do: query
  defp maybe_filter_alias_partition(query, ""), do: query

  defp maybe_filter_alias_partition(query, partition) do
    Ash.Query.filter(query, partition == ^partition)
  end

  defp query_opts(nil), do: []
  defp query_opts(actor), do: [actor: actor]

  defp read_with_actor(query, actor), do: Ash.read(query, query_opts(actor))
  defp read_one_with_actor(query, actor), do: Ash.read_one(query, query_opts(actor))

  defp read_page_with_actor(query, actor) do
    query
    |> read_with_actor(actor)
    |> Page.unwrap()
  end

  defp read_canonical_device(query, actor, include_deleted) do
    query
    |> read_with_actor(actor)
    |> case do
      {:ok, devices} -> {:ok, select_canonical_device(devices, include_deleted)}
      error -> error
    end
  end

  defp select_canonical_device([], _include_deleted), do: nil

  defp select_canonical_device(devices, include_deleted) do
    # Filter out tombstoned/deleted devices
    valid_devices =
      Enum.reject(devices, fn device ->
        metadata = device.metadata || %{}

        Map.has_key?(metadata, "_merged_into") or
          String.downcase(to_string(metadata["_deleted"] || "")) == "true" or
          (not include_deleted and not is_nil(device.deleted_at))
      end)

    List.first(valid_devices) || List.first(devices)
  end

  defp maybe_record_for_ip(nil, _ip), do: []
  defp maybe_record_for_ip(device, ip), do: [{ip, build_record_from_device(device)}]

  defp maybe_record_for_ip_row(nil, _ip), do: []
  defp maybe_record_for_ip_row(row, ip), do: [{ip, build_record_from_row(row)}]

  defp build_record_from_device(nil), do: nil

  defp build_record_from_device(device) do
    partition = device_partition(device)
    metadata = device.metadata || %{}

    attributes =
      %{}
      |> maybe_put("ip", device.ip)
      |> maybe_put("partition", partition)
      |> maybe_put("hostname", device.hostname)
      |> maybe_put("source", metadata["discovery_source"])

    %{
      canonical_device_id: device.uid,
      partition: partition,
      metadata_hash: nil,
      attributes: attributes,
      updated_at: DateTime.utc_now()
    }
  end

  defp build_record_from_row(row) do
    uid = row["uid"]
    partition = row_partition(row)
    metadata = row["metadata"] || %{}

    attributes =
      %{}
      |> maybe_put("ip", row["ip"])
      |> maybe_put("partition", partition)
      |> maybe_put("hostname", row["hostname"])
      |> maybe_put("source", metadata["discovery_source"])

    %{
      canonical_device_id: uid,
      partition: partition,
      metadata_hash: nil,
      attributes: attributes,
      updated_at: DateTime.utc_now()
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp lookup_partition(opts) do
    case Keyword.get(opts, :partition) do
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end

  defp device_partition(%{partition: partition}) when is_binary(partition) and partition != "" do
    partition
  end

  defp device_partition(%{uid: uid}), do: partition_from_device_id(uid)
  defp device_partition(_device), do: "default"

  defp row_partition(row) do
    case row["partition"] do
      value when is_binary(value) and value != "" -> value
      _ -> partition_from_device_id(row["uid"])
    end
  end

  defp split_partition_ip(value) do
    case String.split(value, ":", parts: 2) do
      [partition, ip] -> {partition, ip}
      _ -> {"", value}
    end
  end

  defp partition_from_device_id(device_id) when is_binary(device_id) do
    case String.split(device_id, ":", parts: 2) do
      [partition, _rest] when partition != "sr" -> partition
      _ -> "default"
    end
  end

  defp partition_from_device_id(_), do: "default"

  defp normalize_mac(mac) when is_binary(mac) do
    mac
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[:\-\.]/, "")
  end

  defp normalize_mac(_), do: ""

  defp emit_lookup_telemetry(result, start_time) do
    duration = System.monotonic_time(:microsecond) - start_time

    :telemetry.execute(
      [:serviceradar, :identity, :lookup],
      %{
        duration: duration,
        count: 1
      },
      %{
        found: result.found,
        resolved_via: result.resolved_via
      }
    )
  end

  defp emit_authoritative_fallback_telemetry(0, _reason), do: :ok

  defp emit_authoritative_fallback_telemetry(count, reason) do
    :telemetry.execute(
      [:serviceradar, :identity, :lookup, :authoritative_fallback],
      %{count: count},
      %{reason: reason}
    )
  end
end
