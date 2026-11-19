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
  alias ServiceRadar.Identity.AliasPolicy
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.AliasRecency

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

  # Page size for the streamed batch device reads. Bounded deliberately: streaming
  # opts out of Ash's max_page_size clamp, so this is the only thing keeping a
  # large address batch from being requested as a single page.
  @device_read_batch_size 250

  @doc """
  Resolve identity keys to a canonical device record.

  Tries each key in order until a match is found. Returns the first match
  with information about which key was used. A database read error stops the
  lookup and returns `{:error, reason}` without trying later keys or IP
  fallbacks; only a successful read with no match advances to another key.

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
      case do_lookup(keys, opts) do
        {:error, _reason} = error ->
          error

        result ->
          emit_lookup_telemetry(result, start_time)
          {:ok, result}
      end
    end
  end

  @doc """
  Batch lookup for multiple IPs.

  Optimized for sweep result processing - looks up canonical identities
  for a list of IPs in bulk. Which holder an address resolves to when several
  devices hold it is described in `batch_resolve_by_ip/2`.

  ## Options

  - `:use_cache` - Whether to use identity cache (default: false)
  - `:actor` - Actor for authorization context
  - `:include_deleted` - Fall back to a soft-deleted holder when no live device
    holds the address (default: false)
  - `:include_detected` - Also consider detected aliases (default: false)
  - `:partition` - Partition to resolve in (default: "default")
  """
  @spec batch_lookup_by_ip([String.t()], keyword()) :: %{String.t() => canonical_record()}
  def batch_lookup_by_ip(ips, opts \\ []) when is_list(ips) do
    ips
    |> resolve_ips(opts, Keyword.get(opts, :include_detected, false))
    |> Map.new(fn {ip, {record, _detected_alias}} -> {ip, record} end)
  end

  @doc """
  Resolve each address to the device it is attributed to, detected aliases included.

  Returns `{record, detected_alias}` per resolved address. `detected_alias` is the
  `DeviceAliasState` when the winner holds the address only as a detected (not yet
  confirmed) alias, so a caller can confirm it, and `nil` otherwise.

  A device holds an address as its primary IP or through an IP alias. The winner is
  the first live holder in this order:

  1. a confirmed or updated alias seen within the `AliasRecency` window;
  2. the device whose primary IP the address is;
  3. a detected alias seen within the window;
  4. a confirmed or updated alias outside the window;
  5. a detected alias outside the window.

  Alias holders of one kind are taken in `DeviceAliasState.holder_sort/0` order, most
  recently seen first. A stale alias is still used when no fresher live holder exists:
  the address is never dropped for age. A soft-deleted holder is used only when no
  live device holds the address at all (and only with `include_deleted: true`), in the
  order confirmed alias, primary IP, detected alias. That keeps a sweep able to
  restore a soft-deleted device and stops it seeding a new device for an address only
  a tombstone holds. A merged-away holder is not redirected to its survivor.

  Takes the options of `batch_lookup_by_ip/2`; detected aliases are always considered.
  """
  @spec batch_resolve_by_ip([String.t()], keyword()) ::
          %{String.t() => {canonical_record(), DeviceAliasState.t() | nil}}
  def batch_resolve_by_ip(ips, opts \\ []) when is_list(ips) do
    resolve_ips(ips, opts, true)
  end

  defp resolve_ips(ips, opts, include_detected) do
    use_cache = Keyword.get(opts, :use_cache, false)
    actor = Keyword.get(opts, :actor)
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
      alias_candidates =
        lookup_alias_candidates(unique_ips, actor, include_deleted, include_detected, partition)

      {cache_hits, cache_misses} = fetch_cache_hits(unique_ips, use_cache, partition)

      primary_candidates =
        cache_hits
        |> Map.new(fn {ip, record} -> {ip, cached_candidate(record)} end)
        |> Map.merge(lookup_devices_by_ips(cache_misses, actor, include_deleted, partition))

      resolved =
        Enum.reduce(unique_ips, %{}, fn ip, acc ->
          candidates =
            Map.get(alias_candidates, ip, []) ++ List.wrap(Map.get(primary_candidates, ip))

          case candidates do
            [] ->
              acc

            _ ->
              winner = Enum.min_by(candidates, &candidate_rank/1)
              Map.put(acc, ip, {winner.record, winner.detected_alias})
          end
        end)

      resolved
      |> Map.drop(Map.keys(cache_hits))
      |> cache_resolved(use_cache)

      resolved
    end
  end

  # Lower ranks win; Enum.min_by/2 keeps the first of equal ranks, so holders of one
  # kind keep their holder_sort order. See batch_resolve_by_ip/2.
  defp candidate_rank(%{live?: true, source: :confirmed, recent?: true}), do: 0
  defp candidate_rank(%{live?: true, source: :primary}), do: 1
  defp candidate_rank(%{live?: true, source: :detected, recent?: true}), do: 2
  defp candidate_rank(%{live?: true, source: :confirmed}), do: 3
  defp candidate_rank(%{live?: true, source: :detected}), do: 4
  defp candidate_rank(%{source: :confirmed}), do: 5
  defp candidate_rank(%{source: :primary}), do: 6
  defp candidate_rank(%{source: :detected}), do: 7

  # A cached record is the explicit opt-in read optimisation (see the moduledoc); it
  # stands in for the primary-IP read and carries no liveness, so it is taken as live.
  defp cached_candidate(record) do
    %{record: record, live?: true, source: :primary, recent?: true, detected_alias: nil}
  end

  defp device_candidate(device, source, alias_state \\ nil) do
    %{
      record: build_record_from_device(device),
      live?: live_canonical_candidate?(device),
      source: source,
      recent?: alias_recent?(alias_state),
      detected_alias: if(source == :detected, do: alias_state)
    }
  end

  defp alias_recent?(nil), do: true
  defp alias_recent?(%DeviceAliasState{last_seen_at: seen}), do: AliasRecency.recent?(seen)

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

  # Detected-alias winners are not cached: the cache answers the confirmed-alias and
  # primary-IP question, and a detected alias is not yet an identity.
  defp cache_resolved(resolved, true) do
    Enum.each(resolved, fn
      {ip, {record, nil}} -> IdentityCache.put(ip, record)
      {_ip, {_record, _detected_alias}} -> :ok
    end)
  end

  defp cache_resolved(_resolved, false), do: :ok

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

      {:error, _reason} = error ->
        {:halt, error}
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

      {:ok, nil} ->
        Device
        |> Ash.Query.for_read(:by_ip, %{
          ip: ip,
          partition: partition,
          include_deleted: include_deleted
        })
        |> read_canonical_device(actor, include_deleted)

      {:error, _reason} = error ->
        error
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
    |> read_stream_with_actor(actor)
    |> case do
      {:ok, devices} ->
        ash_results =
          devices
          |> Enum.group_by(& &1.ip)
          |> Map.new(fn {ip, grouped_devices} ->
            {ip,
             grouped_devices
             |> select_canonical_device(include_deleted)
             |> device_candidate(:primary)}
          end)

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
    # `deleted_at IS NULL` is the FIRST ordering key after the grouping column, and
    # must stay there. Ordering by `modified_time DESC` ahead of liveness is
    # actively self-reinforcing: every sweep write bumps `modified_time` on
    # whichever row it resolved to, so once a tombstone was picked it kept winning
    # and the surviving record sank further down the order on each pass.
    sql = """
    SELECT uid, ip, hostname, metadata, partition, deleted_at
    FROM ocsf_devices
    WHERE ip = ANY($1)
      AND ($2 OR deleted_at IS NULL)
      AND partition = $3
    ORDER BY
      ip ASC,
      CASE WHEN deleted_at IS NULL THEN 0 ELSE 1 END ASC,
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
        |> Map.new(fn {ip, grouped_rows} ->
          {ip, grouped_rows |> select_canonical_row() |> row_candidate()}
        end)

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

  # Mirrors select_canonical_device/2: liveness decides, and the dead metadata
  # markers are only a secondary filter. The ORDER BY above already puts live rows
  # first; this keeps the choice correct even if that ordering is ever changed.
  defp select_canonical_row(rows), do: Enum.find(rows, &live_row?/1) || List.first(rows)

  defp live_row?(row) do
    metadata = row["metadata"] || %{}

    is_nil(row["deleted_at"]) and
      not Map.has_key?(metadata, "_merged_into") and
      String.downcase(to_string(metadata["_deleted"] || "")) != "true"
  end

  defp row_candidate(row) do
    %{
      record: build_record_from_row(row),
      live?: live_row?(row),
      source: :primary,
      recent?: true,
      detected_alias: nil
    }
  end

  # Every holder of each address through an IP alias, as candidates in holder_sort order.
  # A holder whose device is not loaded (soft-deleted, without include_deleted)
  # is no candidate, so the next holder is considered instead.
  defp lookup_alias_candidates(ips, actor, include_deleted, include_detected, partition) do
    states =
      if include_detected, do: [:confirmed, :updated, :detected], else: [:confirmed, :updated]

    case read_alias_states(ips, states, partition, actor) do
      {:ok, []} ->
        %{}

      {:ok, aliases} ->
        devices = load_alias_devices(aliases, actor, include_deleted)

        aliases
        |> Enum.flat_map(fn alias_state ->
          case Map.get(devices, alias_state.device_id) do
            nil ->
              []

            device ->
              [
                {alias_state.alias_value,
                 device_candidate(device, alias_source(alias_state), alias_state)}
              ]
          end
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      {:error, _} ->
        %{}
    end
  rescue
    e ->
      Logger.warning("Alias lookup failed: #{inspect(e)}")
      %{}
  end

  defp alias_source(%DeviceAliasState{state: :detected}), do: :detected
  defp alias_source(%DeviceAliasState{}), do: :confirmed

  defp read_alias_states(ips, states, partition, actor) do
    case Enum.filter(ips, &AliasPolicy.valid_alias_ip?/1) do
      [] ->
        {:ok, []}

      ips ->
        DeviceAliasState
        |> Ash.Query.filter(alias_type == :ip and alias_value in ^ips and state in ^states)
        |> maybe_filter_alias_partition(partition)
        |> Ash.Query.sort(DeviceAliasState.holder_sort())
        |> read_with_actor(actor)
    end
  end

  defp load_alias_devices(aliases, actor, include_deleted) do
    device_ids = aliases |> Enum.map(& &1.device_id) |> Enum.uniq()

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: include_deleted})
    |> Ash.Query.filter(uid in ^device_ids)
    |> read_stream_with_actor(actor)
    |> case do
      {:ok, records} -> Map.new(records, &{&1.uid, &1})
      _ -> %{}
    end
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
      |> Ash.Query.sort(DeviceAliasState.holder_sort())

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

  # Streams rather than taking one page, and that distinction is load-bearing.
  #
  # Ash clamps a requested page down to the action's `max_page_size` with a silent
  # `Enum.min/1`, then computes `more?` against the *requested* limit rather than
  # the clamped one -- so a single page comes back short AND reports itself
  # complete. `Page.unwrap/1` discarded `more?` regardless, leaving no signal.
  #
  # Both callers resolve a BATCH and treat an absent row as "no such device", so a
  # clamped page does not degrade gracefully, it produces wrong answers: unknown
  # devices for addresses that exist, and -- where a live record shares an address
  # with its merged-away tombstone -- a candidate list holding only the tombstone.
  # That is how a soft-deleted device came to win canonical selection and absorb
  # live observations while the surviving record went stale.
  defp read_stream_with_actor(query, actor) do
    opts = Keyword.put(query_opts(actor), :batch_size, @device_read_batch_size)

    {:ok, query |> Ash.stream!(opts) |> Enum.to_list()}
  rescue
    exception -> {:error, exception}
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

  # A soft-deleted device is never preferred over a live one sharing the same IP.
  #
  # Callers on the sweep path pass `include_deleted: true` on purpose, because an
  # IP may only be carried by a merged-away record. That used to let a tombstone
  # win the selection outright: `deleted_at` was consulted only when
  # `include_deleted` was false, so with it true the list was ordered by `uid` and
  # which of a survivor and its own tombstone came first was decided by UUID.
  # Every write keyed off the result then landed on the tombstone --
  # `last_seen_time`, `is_available`, and the `device_agent_availability` rows --
  # while the surviving record was never refreshed again and read as stale.
  #
  # The `_merged_into` / `_deleted` metadata markers are kept as candidates for
  # rejection but are NOT load-bearing: nothing in this codebase writes either
  # key. They are Go-era markers, and relying on them is what left `deleted_at`
  # unchecked.
  defp select_canonical_device(devices, _include_deleted) do
    live = Enum.filter(devices, &live_canonical_candidate?/1)

    # The trailing fallback preserves the previous contract: a non-empty list
    # always resolves to some device, so a caller that has only a tombstone to go
    # on still gets it and can follow the merge redirect itself.
    List.first(live) || List.first(devices)
  end

  defp live_canonical_candidate?(device) do
    metadata = device.metadata || %{}

    is_nil(device.deleted_at) and
      not Map.has_key?(metadata, "_merged_into") and
      String.downcase(to_string(metadata["_deleted"] || "")) != "true"
  end

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
