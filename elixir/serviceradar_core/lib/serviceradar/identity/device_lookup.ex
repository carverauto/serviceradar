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
  """

  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier}

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

  @doc """
  Resolve identity keys to a canonical device record.

  Tries each key in order until a match is found. Returns the first match
  with information about which key was used.

  ## Options

  - `:ip_hint` - Optional IP to append as a fallback key
  - `:partition` - Partition context for partition-scoped lookups
  - `:use_cache` - Whether to use the identity cache (default: true)
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
  """
  @spec batch_lookup_by_ip([String.t()], keyword()) :: %{String.t() => canonical_record()}
  def batch_lookup_by_ip(ips, opts \\ []) when is_list(ips) do
    use_cache = Keyword.get(opts, :use_cache, true)
    actor = Keyword.get(opts, :actor)

    unique_ips =
      ips
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if Enum.empty?(unique_ips) do
      %{}
    else
      {cache_hits, cache_misses} =
        if use_cache do
          IdentityCache.get_batch(unique_ips)
        else
          {%{}, unique_ips}
        end

      db_results = lookup_devices_by_ips(cache_misses, actor)

      # Cache the DB results
      if use_cache do
        Enum.each(db_results, fn {ip, record} ->
          IdentityCache.put(ip, record)
        end)
      end

      Map.merge(cache_hits, db_results)
    end
  end

  # Private functions

  defp normalize_identity_keys(keys, opts) do
    seen = MapSet.new()

    normalized =
      keys
      |> Enum.reduce({[], seen}, fn key, {acc, seen_set} ->
        kind = normalize_kind(key[:kind] || key["kind"])
        value = String.trim(to_string(key[:value] || key["value"] || ""))

        if kind == :unspecified or value == "" do
          {acc, seen_set}
        else
          signature = "#{kind}|#{value}"

          if MapSet.member?(seen_set, signature) do
            {acc, seen_set}
          else
            {[%{kind: kind, value: value} | acc], MapSet.put(seen_set, signature)}
          end
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    # Add IP hint if provided
    case Keyword.get(opts, :ip_hint) do
      nil ->
        normalized

      ip_hint ->
        ip = String.trim(ip_hint)
        signature = "ip|#{ip}"
        seen = normalized |> Enum.map(&"#{&1.kind}|#{&1.value}") |> MapSet.new()

        if ip != "" and not MapSet.member?(seen, signature) do
          normalized ++ [%{kind: :ip, value: ip}]
        else
          normalized
        end
    end
  end

  defp normalize_kind(:device_id), do: :device_id
  defp normalize_kind(:partition_ip), do: :partition_ip
  defp normalize_kind(:ip), do: :ip
  defp normalize_kind(:mac), do: :mac
  defp normalize_kind(:armis_id), do: :armis_id
  defp normalize_kind(:netbox_id), do: :netbox_id
  defp normalize_kind(:integration_id), do: :integration_id
  defp normalize_kind("device_id"), do: :device_id
  defp normalize_kind("partition_ip"), do: :partition_ip
  defp normalize_kind("ip"), do: :ip
  defp normalize_kind("mac"), do: :mac
  defp normalize_kind("armis_id"), do: :armis_id
  defp normalize_kind("netbox_id"), do: :netbox_id
  defp normalize_kind("integration_id"), do: :integration_id
  defp normalize_kind(_), do: :unspecified

  defp do_lookup(keys, opts) do
    use_cache = Keyword.get(opts, :use_cache, true)
    actor = Keyword.get(opts, :actor)

    Enum.reduce_while(
      keys,
      %{found: false, record: nil, matched_key: nil, resolved_via: "miss"},
      fn key, _acc ->
        # Try cache first for IP-based lookups
        cached_record =
          if use_cache and key.kind == :ip do
            IdentityCache.get(key.value)
          else
            nil
          end

        if cached_record do
          {:halt, %{found: true, record: cached_record, matched_key: key, resolved_via: "cache"}}
        else
          case lookup_by_key(key, actor) do
            {:ok, nil} ->
              {:cont, %{found: false, record: nil, matched_key: nil, resolved_via: "miss"}}

            {:ok, device} ->
              record = build_record_from_device(device)

              # Cache the result
              if use_cache and key.kind == :ip do
                IdentityCache.put(key.value, record)
              end

              {:halt, %{found: true, record: record, matched_key: key, resolved_via: "db"}}

            {:error, reason} ->
              Logger.debug(
                "Identity lookup failed for #{key.kind}:#{key.value}: #{inspect(reason)}"
              )

              {:cont, %{found: false, record: nil, matched_key: nil, resolved_via: "error"}}
          end
        end
      end
    )
  end

  defp lookup_by_key(%{kind: :device_id, value: device_id}, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    Device
    |> Ash.Query.for_read(:by_uid, %{uid: device_id})
    |> Ash.read_one(query_opts)
  end

  defp lookup_by_key(%{kind: :partition_ip, value: value}, actor) do
    {partition, ip} = split_partition_ip(value)

    case lookup_by_key(%{kind: :ip, value: ip}, actor) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, device} ->
        # Check partition match
        device_partition = partition_from_device_id(device.uid)

        if partition == "" or device_partition == partition do
          {:ok, device}
        else
          {:ok, nil}
        end

      error ->
        error
    end
  end

  defp lookup_by_key(%{kind: :ip, value: ip}, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    Device
    |> Ash.Query.for_read(:by_ip, %{ip: ip})
    |> Ash.read(query_opts)
    |> case do
      {:ok, devices} -> {:ok, select_canonical_device(devices)}
      error -> error
    end
  end

  defp lookup_by_key(%{kind: :mac, value: mac}, actor) do
    normalized_mac = normalize_mac(mac)
    query_opts = if actor, do: [actor: actor], else: []

    Device
    |> Ash.Query.for_read(:by_mac, %{mac: normalized_mac})
    |> Ash.read(query_opts)
    |> case do
      {:ok, devices} -> {:ok, select_canonical_device(devices)}
      error -> error
    end
  end

  defp lookup_by_key(%{kind: id_type, value: id_value}, actor)
       when id_type in [:armis_id, :netbox_id, :integration_id] do
    query_opts = if actor, do: [actor: actor], else: []

    identifier_type =
      case id_type do
        :armis_id -> :armis_device_id
        :netbox_id -> :netbox_device_id
        :integration_id -> :integration_id
      end

    DeviceIdentifier
    |> Ash.Query.for_read(:lookup, %{
      identifier_type: identifier_type,
      identifier_value: id_value,
      partition: "default"
    })
    |> Ash.read(query_opts)
    |> case do
      {:ok, [identifier | _]} ->
        Device
        |> Ash.Query.for_read(:by_uid, %{uid: identifier.device_id})
        |> Ash.read_one(query_opts)

      {:ok, []} ->
        {:ok, nil}

      error ->
        error
    end
  end

  defp lookup_by_key(_key, _actor), do: {:ok, nil}

  defp lookup_devices_by_ips([], _actor), do: %{}

  defp lookup_devices_by_ips(ips, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    # Batch query for all IPs
    Device
    |> Ash.Query.filter(ip in ^ips)
    |> Ash.read(query_opts)
    |> case do
      {:ok, devices} ->
        devices
        |> Enum.group_by(& &1.ip)
        |> Enum.map(fn {ip, grouped_devices} ->
          device = select_canonical_device(grouped_devices)

          if device do
            {ip, build_record_from_device(device)}
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      {:error, _} ->
        %{}
    end
  end

  defp select_canonical_device([]), do: nil

  defp select_canonical_device(devices) do
    # Filter out tombstoned/deleted devices
    valid_devices =
      Enum.reject(devices, fn device ->
        metadata = device.metadata || %{}

        Map.has_key?(metadata, "_merged_into") or
          String.downcase(to_string(metadata["_deleted"] || "")) == "true"
      end)

    List.first(valid_devices) || List.first(devices)
  end

  defp build_record_from_device(nil), do: nil

  defp build_record_from_device(device) do
    partition = partition_from_device_id(device.uid)
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
end
