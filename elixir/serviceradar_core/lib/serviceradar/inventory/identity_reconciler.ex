defmodule ServiceRadar.Inventory.IdentityReconciler do
  @moduledoc """
  Device Identity and Reconciliation Engine (DIRE) for Elixir.

  Port of the Go IdentityEngine that resolves device updates to canonical
  ServiceRadar device IDs. This module is the single source of truth for
  device identity resolution.

  ## Resolution Priority

  1. Strong identifiers (Armis ID > Integration ID > NetBox ID > MAC)
     - Hash to deterministic `sr:` UUID
  2. Existing `sr:` UUID in update
     - Preserve as-is
  3. IP-only (no strong identifier)
     - Lookup existing device by IP, or generate new `sr:` UUID

  ## Strong Identifier Priority

  Identifiers are processed in priority order:
  1. `armis_device_id` - Armis platform device ID
  2. `integration_id` - Generic integration ID
  3. `netbox_device_id` - NetBox device ID
  4. `mac` - MAC address (normalized)

  IP is a "weak" identifier only used when no strong identifiers are present.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, Interface, MergeAudit}
  alias ServiceRadar.Monitoring.{Alert, ServiceCheck}

  require Ash.Query
  require Logger
  import Bitwise

  # Identifier types in priority order (lower index = higher priority)
  @identifier_priority [:armis_device_id, :integration_id, :netbox_device_id, :mac]

  @type strong_identifiers :: %{
          armis_id: String.t() | nil,
          integration_id: String.t() | nil,
          netbox_id: String.t() | nil,
          mac: String.t() | nil,
          ip: String.t() | nil,
          partition: String.t()
        }

  @type device_update :: %{
          device_id: String.t() | nil,
          ip: String.t() | nil,
          mac: String.t() | nil,
          partition: String.t() | nil,
          metadata: map() | nil
        }

  @doc """
  Resolve a device update to a canonical ServiceRadar device ID.

  Returns the resolved device ID (either existing or newly generated).
  """
  @spec resolve_device_id(device_update(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_device_id(update, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    # Skip service component IDs
    if service_device_id?(update.device_id) do
      {:ok, update.device_id}
    else
      do_resolve_device_id(update, actor)
    end
  end

  defp do_resolve_device_id(update, actor) do
    ids = extract_strong_identifiers(update)

    # Step 1: Lookup by strong identifiers (merge conflicts if multiple IDs found)
    with {:ok, device_id} when is_binary(device_id) and device_id != "" <-
           lookup_by_strong_identifiers(ids, actor, update.device_id) do
      {:ok, device_id}
    else
      _ -> resolve_fallback_device_id(update, ids, actor)
    end
  end

  defp resolve_fallback_device_id(update, ids, actor) do
    if serviceradar_uuid?(update.device_id) do
      {:ok, update.device_id}
    else
      case lookup_by_ip(ids, actor) do
        {:ok, device_id} when is_binary(device_id) and device_id != "" ->
          {:ok, device_id}

        _ ->
          {:ok, generate_deterministic_device_id(ids)}
      end
    end
  end

  @doc """
  Extract strong identifiers from a device update.
  """
  @spec extract_strong_identifiers(device_update()) :: strong_identifiers()
  def extract_strong_identifiers(update) do
    metadata = update[:metadata] || %{}
    partition = (update[:partition] || "default") |> String.trim()

    %{
      armis_id: get_trimmed(metadata, "armis_device_id"),
      integration_id: get_integration_id(metadata),
      netbox_id: get_trimmed(metadata, "netbox_device_id"),
      mac: normalize_mac(update[:mac]),
      ip: (update[:ip] || "") |> String.trim(),
      partition: partition
    }
  end

  defp get_integration_id(metadata) do
    case metadata["integration_type"] do
      "netbox" ->
        get_trimmed(metadata, "integration_id")

      _ ->
        get_trimmed(metadata, "integration_id")
    end
  end

  defp get_trimmed(map, key) when is_map(map) do
    case map[key] do
      nil ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Check if any strong identifier is present.
  """
  @spec has_strong_identifier?(strong_identifiers()) :: boolean()
  def has_strong_identifier?(ids) do
    ids.armis_id != nil or
      ids.integration_id != nil or
      ids.netbox_id != nil or
      ids.mac != nil
  end

  @doc """
  Get the highest priority identifier type and value.
  """
  @spec highest_priority_identifier(strong_identifiers()) :: {atom() | nil, String.t() | nil}
  def highest_priority_identifier(ids) do
    cond do
      ids.armis_id != nil -> {:armis_device_id, ids.armis_id}
      ids.integration_id != nil -> {:integration_id, ids.integration_id}
      ids.netbox_id != nil -> {:netbox_device_id, ids.netbox_id}
      ids.mac != nil -> {:mac, ids.mac}
      true -> {nil, nil}
    end
  end

  @doc """
  Lookup device by strong identifiers in priority order.
  """
  @spec lookup_by_strong_identifiers(strong_identifiers(), term(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def lookup_by_strong_identifiers(ids, actor, preferred_device_id \\ nil) do
    if has_strong_identifier?(ids) do
      matches = lookup_identifier_matches(ids, actor)
      device_ids = matches |> Map.values() |> Enum.map(& &1.device_id) |> Enum.uniq()

      case device_ids do
        [] ->
          {:ok, nil}

        [device_id] ->
          {:ok, device_id}

        _ ->
          canonical_id = select_canonical_device_id(preferred_device_id, matches, actor)
          _ = merge_conflicting_devices(canonical_id, device_ids, matches, actor)
          {:ok, canonical_id}
      end
    else
      {:ok, nil}
    end
  end

  defp get_identifier_value(ids, :armis_device_id), do: ids.armis_id
  defp get_identifier_value(ids, :integration_id), do: ids.integration_id
  defp get_identifier_value(ids, :netbox_device_id), do: ids.netbox_id
  defp get_identifier_value(ids, :mac), do: ids.mac

  defp lookup_device_identifier(id_type, id_value, partition, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    DeviceIdentifier
    |> Ash.Query.for_read(:lookup, %{
      identifier_type: id_type,
      identifier_value: id_value,
      partition: partition
    })
    |> Ash.read(query_opts)
    |> case do
      {:ok, [identifier | _]} -> {:ok, identifier.device_id}
      {:ok, []} -> {:ok, nil}
      {:error, _} = error -> error
    end
  rescue
    e ->
      Logger.warning("Failed to lookup device identifier: #{inspect(e)}")
      {:ok, nil}
  end

  @doc """
  Lookup device by IP address (weak identifier).
  """
  @spec lookup_by_ip(strong_identifiers(), term()) :: {:ok, String.t() | nil} | {:error, term()}
  def lookup_by_ip(ids, actor) do
    if has_strong_identifier?(ids) or ids.ip == "" do
      {:ok, nil}
    else
      do_lookup_by_ip(ids.ip, actor)
    end
  end

  defp do_lookup_by_ip(ip, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    Device
    |> Ash.Query.for_read(:by_ip, %{ip: ip})
    |> Ash.read(query_opts)
    |> case do
      {:ok, [device | _]} ->
        # Only return devices with ServiceRadar UUIDs
        if serviceradar_uuid?(device.uid) do
          {:ok, device.uid}
        else
          {:ok, nil}
        end

      {:ok, []} ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  rescue
    e ->
      Logger.warning("Failed to lookup device by IP: #{inspect(e)}")
      {:ok, nil}
  end

  @doc """
  Generate a deterministic ServiceRadar device ID based on identifiers.

  Uses SHA-256 hash of identifiers to create a reproducible UUID.
  Format: `sr:<uuid>`
  """
  @spec generate_deterministic_device_id(strong_identifiers()) :: String.t()
  def generate_deterministic_device_id(ids) do
    partition = if ids.partition == "", do: "default", else: ids.partition

    # Build seeds from strong identifiers in priority order
    seeds =
      []
      |> maybe_add_seed("armis", ids.armis_id)
      |> maybe_add_seed("integration", ids.integration_id)
      |> maybe_add_seed("netbox", ids.netbox_id)
      |> maybe_add_seed("mac", ids.mac)

    hash_input =
      cond do
        not Enum.empty?(seeds) ->
          # Strong identifiers present - deterministic hash
          "serviceradar-device-v3:partition:#{partition}:" <> Enum.join(seeds, "")

        ids.ip != "" ->
          # IP-only fallback
          "serviceradar-device-v3:partition:#{partition}:ip:#{ids.ip}"

        true ->
          # No identifiers - random UUID
          return_random_uuid()
      end

    if is_binary(hash_input) do
      hash_bytes = :crypto.hash(:sha256, hash_input)
      uuid_from_hash(hash_bytes)
    else
      # Already a UUID string from return_random_uuid()
      hash_input
    end
  end

  defp maybe_add_seed(acc, _prefix, nil), do: acc
  defp maybe_add_seed(acc, prefix, value), do: acc ++ ["#{prefix}:#{value}"]

  defp return_random_uuid do
    "sr:" <> Ecto.UUID.generate()
  end

  defp uuid_from_hash(hash_bytes) when byte_size(hash_bytes) >= 16 do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = hash_bytes

    # Set version (4) and variant (RFC 4122)
    c_versioned = (c &&& 0x0FFF) ||| 0x4000
    d_variant = (d &&& 0x3FFF) ||| 0x8000

    uuid =
      :io_lib.format(
        "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
        [a, b, c_versioned, d_variant, e]
      )
      |> IO.iodata_to_binary()
      |> String.downcase()

    "sr:" <> uuid
  end

  @doc """
  Register device identifiers in the device_identifiers table.
  """
  @spec register_identifiers(String.t(), strong_identifiers(), keyword()) ::
          :ok | {:error, term()}
  def register_identifiers(device_id, ids, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    partition = if ids.partition == "", do: "default", else: ids.partition
    query_opts = if actor, do: [actor: actor], else: []
    canonical_id = resolve_identifier_conflicts(device_id, ids, actor)

    if device_id != nil and device_id != "" and canonical_id != nil and canonical_id != "" and
         device_id != canonical_id and not service_device_id?(device_id) do
      _ =
        merge_devices(device_id, canonical_id,
          actor: actor,
          reason: "identifier_conflict",
          details: %{
            source: "identifier_registration",
            identifiers: %{
              armis_id: ids.armis_id,
              integration_id: ids.integration_id,
              netbox_id: ids.netbox_id,
              mac: ids.mac
            }
          }
        )
    end

    identifiers_to_register =
      []
      |> maybe_add_identifier(canonical_id, :armis_device_id, ids.armis_id, partition)
      |> maybe_add_identifier(canonical_id, :integration_id, ids.integration_id, partition)
      |> maybe_add_identifier(canonical_id, :netbox_device_id, ids.netbox_id, partition)
      |> maybe_add_identifier(canonical_id, :mac, ids.mac, partition)

    results =
      Enum.map(identifiers_to_register, fn params ->
        DeviceIdentifier
        |> Ash.Changeset.for_create(:upsert, params)
        |> Ash.create(query_opts)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      :ok
    else
      {:error, {:identifier_registration_failed, errors}}
    end
  end

  @doc """
  Reconcile duplicate devices by shared strong identifiers.

  Returns stats for observability and logging.
  """
  @spec reconcile_duplicates(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_duplicates(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:identity_reconciliation))
    max_merges = Keyword.get(opts, :max_merges)
    started_at = System.monotonic_time(:millisecond)

    Logger.info("Device identity reconciliation started")

    {identifier_index, scanned_count} = build_identifier_index(actor)

    duplicate_entries =
      identifier_index
      |> Enum.filter(fn {_key, device_ids} -> MapSet.size(device_ids) > 1 end)

    components =
      duplicate_entries
      |> build_duplicate_components()
      |> Enum.filter(&(length(&1) > 1))

    {merge_count, error_count} = merge_components(components, actor, max_merges)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    stats = %{
      identifiers_scanned: scanned_count,
      duplicate_identifier_count: length(duplicate_entries),
      duplicate_components: length(components),
      merges: merge_count,
      errors: error_count,
      duration_ms: duration_ms
    }

    Logger.info("Device identity reconciliation completed: #{inspect(stats)}")

    {:ok, stats}
  rescue
    error ->
      Logger.warning("Device identity reconciliation failed: #{inspect(error)}")
      {:error, error}
  end

  defp lookup_identifier_matches(ids, actor) do
    Enum.reduce(@identifier_priority, %{}, fn id_type, acc ->
      case get_identifier_value(ids, id_type) do
        nil ->
          acc

        id_value ->
          case lookup_device_identifier(id_type, id_value, ids.partition, actor) do
            {:ok, device_id} when is_binary(device_id) and device_id != "" ->
              Map.put(acc, id_type, %{value: id_value, device_id: device_id})

            _ ->
              acc
          end
      end
    end)
  end

  defp select_canonical_device_id(preferred_device_id, matches, actor) do
    device_ids = matches |> Map.values() |> Enum.map(& &1.device_id) |> Enum.uniq()

    cond do
      serviceradar_uuid?(preferred_device_id) and preferred_device_id in device_ids ->
        preferred_device_id

      true ->
        case highest_priority_match(matches) do
          nil -> most_recent_device_id(device_ids, actor)
          device_id -> device_id
        end
    end
  end

  defp highest_priority_match(matches) do
    Enum.find_value(@identifier_priority, fn id_type ->
      case Map.get(matches, id_type) do
        %{device_id: device_id} -> device_id
        _ -> nil
      end
    end)
  end

  defp most_recent_device_id([], _actor), do: nil

  defp most_recent_device_id(device_ids, actor) do
    query =
      Device
      |> Ash.Query.filter(uid in ^device_ids)
      |> Ash.Query.for_read(:read, %{}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, devices} when devices != [] ->
        devices
        |> Enum.max_by(fn device -> device.last_seen_time || ~U[1970-01-01 00:00:00Z] end)
        |> Map.get(:uid)

      _ ->
        List.first(device_ids)
    end
  end

  defp merge_conflicting_devices(canonical_id, device_ids, matches, actor) do
    details = %{
      identifiers:
        Enum.map(matches, fn {id_type, %{value: value, device_id: device_id}} ->
          %{type: id_type, value: value, device_id: device_id}
        end)
    }

    device_ids
    |> Enum.reject(&(&1 == canonical_id))
    |> Enum.each(fn from_id ->
      _ =
        merge_devices(from_id, canonical_id,
          actor: actor,
          reason: "identifier_conflict",
          details: details
        )
    end)
  end

  defp resolve_identifier_conflicts(device_id, ids, actor) do
    matches = lookup_identifier_matches(ids, actor)
    device_ids = matches |> Map.values() |> Enum.map(& &1.device_id) |> Enum.uniq()

    case device_ids do
      [] ->
        device_id

      [only_id] ->
        only_id

      _ ->
        canonical_id = select_canonical_device_id(device_id, matches, actor)
        _ = merge_conflicting_devices(canonical_id, device_ids, matches, actor)
        canonical_id
    end
  end

  defp build_identifier_index(actor) do
    query =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type in ^@identifier_priority)
      |> Ash.Query.select([:device_id, :identifier_type, :identifier_value, :partition])

    Ash.stream!(query, actor: actor, batch_size: 2000)
    |> Enum.reduce({%{}, 0}, fn record, {acc, count} ->
      device_id = normalize_identifier_value(record.device_id)
      identifier_value = normalize_identifier_value(record.identifier_value)

      cond do
        device_id == nil ->
          {acc, count + 1}

        identifier_value == nil ->
          {acc, count + 1}

        service_device_id?(device_id) ->
          {acc, count + 1}

        true ->
          partition = normalize_identifier_value(record.partition) || "default"
          key = {partition, record.identifier_type, identifier_value}

          updated =
            Map.update(acc, key, MapSet.new([device_id]), fn set ->
              MapSet.put(set, device_id)
            end)

          {updated, count + 1}
      end
    end)
  end

  defp normalize_identifier_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_identifier_value(_), do: nil

  defp build_duplicate_components(duplicate_entries) do
    parents =
      Enum.reduce(duplicate_entries, %{}, fn {_key, device_ids}, acc ->
        ids = device_ids |> MapSet.to_list() |> Enum.uniq()
        acc = Enum.reduce(ids, acc, &Map.put_new(&2, &1, &1))

        case ids do
          [first | rest] ->
            Enum.reduce(rest, acc, fn id, parents -> union_devices(parents, first, id) end)

          _ ->
            acc
        end
      end)

    parents
    |> Map.keys()
    |> Enum.reduce(%{}, fn device_id, acc ->
      root = find_device_root(parents, device_id)
      Map.update(acc, root, [device_id], &[device_id | &1])
    end)
    |> Map.values()
  end

  defp find_device_root(parents, device_id) do
    parent = Map.get(parents, device_id, device_id)

    if parent == device_id do
      device_id
    else
      find_device_root(parents, parent)
    end
  end

  defp union_devices(parents, device_a, device_b) do
    root_a = find_device_root(parents, device_a)
    root_b = find_device_root(parents, device_b)

    if root_a == root_b do
      parents
    else
      Map.put(parents, root_b, root_a)
    end
  end

  defp merge_components(components, actor, max_merges) do
    Enum.reduce_while(components, {0, 0}, fn device_ids, {merged, errors} ->
      canonical_id = choose_canonical_device_id(device_ids, actor)

      {merged_count, error_count} =
        device_ids
        |> Enum.reject(&(&1 == canonical_id))
        |> Enum.reduce_while({0, 0}, fn from_id, {local_merged, local_errors} ->
          if max_merges && merged + local_merged >= max_merges do
            {:halt, {local_merged, local_errors}}
          else
            case merge_devices(from_id, canonical_id,
                   actor: actor,
                   reason: "identifier_backfill",
                   details: %{source: "scheduled_reconciliation"}
                 ) do
              :ok ->
                {:cont, {local_merged + 1, local_errors}}

              {:error, reason} ->
                Logger.warning(
                  "Failed to merge device #{from_id} into #{canonical_id}: #{inspect(reason)}"
                )

                {:cont, {local_merged, local_errors + 1}}
            end
          end
        end)

      total_merged = merged + merged_count
      total_errors = errors + error_count

      if max_merges && total_merged >= max_merges do
        {:halt, {total_merged, total_errors}}
      else
        {:cont, {total_merged, total_errors}}
      end
    end)
  end

  defp choose_canonical_device_id(device_ids, actor) do
    candidates = Enum.filter(device_ids, &serviceradar_uuid?/1)
    candidates = if candidates == [], do: device_ids, else: candidates

    most_recent_device_id(candidates, actor) || List.first(candidates)
  end

  @doc """
  Merge a duplicate device into a canonical device and reassign related records.
  """
  @spec merge_devices(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def merge_devices(from_device_id, to_device_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:device_merge))
    reason = Keyword.get(opts, :reason, "identity_resolution")
    details = Keyword.get(opts, :details, %{})

    if from_device_id == to_device_id do
      :ok
    else
      resources = [
        Device,
        DeviceIdentifier,
        Interface,
        MergeAudit,
        ServiceCheck,
        Alert,
        Agent,
        DeviceAliasState
      ]

      Ash.transaction(resources, fn ->
        with {:ok, %Device{} = from_device} <- Device.get_by_uid(from_device_id, actor: actor),
             {:ok, %Device{} = _to_device} <- Device.get_by_uid(to_device_id, actor: actor),
             :ok <- reassign_device_identifiers(from_device_id, to_device_id, actor),
             :ok <- reassign_service_checks(from_device_id, to_device_id, actor),
             :ok <- reassign_alerts(from_device_id, to_device_id, actor),
             :ok <- reassign_agents(from_device_id, to_device_id, actor),
             :ok <- reassign_alias_states(from_device_id, to_device_id, actor),
             :ok <- delete_interfaces(from_device_id, actor),
             {:ok, _merge} <-
               MergeAudit.record(%{
                 from_device_id: from_device_id,
                 to_device_id: to_device_id,
                 reason: reason,
                 source: "identity_reconciler",
                 details: details
               }, actor: actor),
             {:ok, _} <- Ash.destroy(from_device, actor: actor, action: :destroy) do
          :ok
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:ok, other} -> other
        {:error, _} = error -> error
      end
    end
  end

  defp reassign_device_identifiers(from_id, to_id, actor) do
    bulk_reassign(DeviceIdentifier, :reassign_device, {:==, [:device_id], from_id}, %{device_id: to_id}, actor)
  end

  defp reassign_service_checks(from_id, to_id, actor) do
    bulk_reassign(ServiceCheck, :reassign_device, {:==, [:device_uid], from_id}, %{device_uid: to_id}, actor)
  end

  defp reassign_alerts(from_id, to_id, actor) do
    bulk_reassign(Alert, :reassign_device, {:==, [:device_uid], from_id}, %{device_uid: to_id}, actor)
  end

  defp reassign_agents(from_id, to_id, actor) do
    bulk_reassign(Agent, :reassign_device, {:==, [:device_uid], from_id}, %{device_uid: to_id}, actor)
  end

  defp reassign_alias_states(from_id, to_id, actor) do
    bulk_reassign(DeviceAliasState, :reassign_device, {:==, [:device_id], from_id}, %{device_id: to_id}, actor)
  end

  defp delete_interfaces(from_id, actor) do
    query =
      Interface
      |> Ash.Query.filter(device_id == ^from_id)
      |> Ash.Query.for_read(:read, %{}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        :ok

      {:ok, records} ->
        case Ash.bulk_destroy(records, :destroy, %{}, actor: actor) do
          {:ok, _} -> :ok
          :ok -> :ok
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp bulk_reassign(resource, action, _filter_expr, attrs, actor) do
    query =
      resource
      |> Ash.Query.filter(_filter_expr)
      |> Ash.Query.for_read(:read, %{}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        :ok

      {:ok, records} ->
        case Ash.bulk_update(records, action, attrs, actor: actor) do
          {:ok, _} -> :ok
          :ok -> :ok
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp maybe_add_identifier(acc, _device_id, _id_type, nil, _partition), do: acc

  defp maybe_add_identifier(acc, device_id, id_type, id_value, partition) do
    [
      %{
        device_id: device_id,
        identifier_type: id_type,
        identifier_value: id_value,
        partition: partition,
        confidence: :strong,
        source: "identity_reconciler"
      }
      | acc
    ]
  end

  @doc """
  Record a device merge in the audit trail.
  """
  @spec record_merge(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def record_merge(from_device_id, to_device_id, reason, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    confidence_score = Keyword.get(opts, :confidence_score)
    details = Keyword.get(opts, :details, %{})
    query_opts = if actor, do: [actor: actor], else: []

    MergeAudit
    |> Ash.Changeset.for_create(:record, %{
      from_device_id: from_device_id,
      to_device_id: to_device_id,
      reason: reason,
      confidence_score: confidence_score,
      source: "identity_reconciler",
      details: details
    })
    |> Ash.create(query_opts)
  end

  # Utility functions

  @doc """
  Check if a device ID is a ServiceRadar-generated UUID.
  """
  @spec serviceradar_uuid?(String.t() | nil) :: boolean()
  def serviceradar_uuid?(nil), do: false
  def serviceradar_uuid?(device_id), do: String.starts_with?(device_id, "sr:")

  @doc """
  Check if a device ID is for a ServiceRadar service component.
  """
  @spec service_device_id?(String.t() | nil) :: boolean()
  def service_device_id?(nil), do: false
  def service_device_id?(device_id), do: String.starts_with?(device_id, "serviceradar:")

  @doc """
  Normalize a MAC address to uppercase without separators.
  """
  @spec normalize_mac(String.t() | nil) :: String.t() | nil
  def normalize_mac(nil), do: nil

  def normalize_mac(mac) do
    normalized =
      mac
      |> String.trim()
      |> String.upcase()
      |> String.replace(":", "")
      |> String.replace("-", "")
      |> String.replace(".", "")

    if normalized == "", do: nil, else: normalized
  end

  @doc """
  Check if a device ID looks like a legacy partition:IP format.
  """
  @spec legacy_ip_based_id?(String.t() | nil) :: boolean()
  def legacy_ip_based_id?(nil), do: false

  def legacy_ip_based_id?(device_id) do
    if serviceradar_uuid?(device_id) or service_device_id?(device_id) do
      false
    else
      case String.split(device_id, ":", parts: 2) do
        [_partition, ip] ->
          # Check if second part looks like an IP
          String.contains?(ip, ".") or String.contains?(ip, ":")

        _ ->
          false
      end
    end
  end
end
