defmodule ServiceRadar.Inventory.DeviceSourceObservationIngestor do
  @moduledoc """
  Activates complete plugin inventory snapshots as source observations.

  Device reconciliation runs first. This module then resolves each stable
  source integration identifier to its canonical UID and atomically upserts
  present rows, marks prior rows absent, and advances source snapshot state.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Repo

  require Logger

  @max_devices 100_000
  @max_metadata_bytes 16 * 1024
  @lookup_chunk_size 5_000
  @db_prefix "platform"
  @observations_table "device_source_observations"
  @snapshots_table "device_source_snapshots"
  @hash_pattern ~r/^[0-9a-f]{64}$/i
  @instance_pattern ~r/^[A-Za-z0-9._-]{1,128}$/
  @source_pattern ~r/^[a-z0-9][a-z0-9_.-]{0,127}$/
  @metadata_key_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/
  @replace_observation_fields [
    :device_id,
    :source_integration_id,
    :collection_id,
    :content_hash,
    :query_hash,
    :present,
    :last_observed_at,
    :absent_since,
    :hostname,
    :ip,
    :mac,
    :serial_number,
    :vendor_name,
    :model,
    :device_type,
    :site_name,
    :management_status,
    :metadata,
    :updated_at
  ]
  @replace_snapshot_fields [
    :collection_id,
    :content_hash,
    :query_hash,
    :observed_at,
    :activated_at,
    :device_count,
    :absent_count,
    :metadata,
    :updated_at
  ]

  @spec ingest(map(), [map()], map(), keyword()) :: :ok | {:error, term()}
  def ingest(envelope, updates, context, opts \\ [])

  def ingest(envelope, updates, context, opts) when is_map(envelope) and is_list(updates) do
    if complete_snapshot?(envelope) do
      resolver = Keyword.get(opts, :resolver, &resolve_device_ids/2)
      activator = Keyword.get(opts, :activator, &activate_snapshot/2)

      with {:ok, snapshot, source_devices} <- normalize_snapshot(envelope, updates, context),
           {:ok, device_ids} <- resolver.(source_devices, snapshot.partition),
           {:ok, observations} <- attach_device_ids(source_devices, device_ids) do
        normalize_activation_result(activator.(snapshot, observations))
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("Device source observation ingest failed: #{Exception.message(error)}")
      {:error, :source_observation_ingest_failed}
  end

  def ingest(_envelope, _updates, _context, _opts), do: :ok

  @doc """
  Activates a fully resolved source collection.

  This entry point is used when the source sync has already reconciled typed
  identifiers to canonical device UIDs. It shares the same transactional
  activation path and stale/idempotent protections as plugin snapshots.
  """
  @spec activate_resolved(map(), [map()], keyword()) :: :ok | {:error, term()}
  def activate_resolved(snapshot, observations, opts \\ [])

  def activate_resolved(snapshot, observations, opts)
      when is_map(snapshot) and is_list(observations) do
    activator = Keyword.get(opts, :activator, &activate_snapshot/2)

    with :ok <- validate_resolved_snapshot(snapshot, observations) do
      normalize_activation_result(activator.(snapshot, observations))
    end
  rescue
    error ->
      Logger.warning("Resolved source observation activation failed: #{Exception.message(error)}")
      {:error, :source_observation_ingest_failed}
  end

  def activate_resolved(_snapshot, _observations, _opts),
    do: {:error, :invalid_resolved_source_snapshot}

  @doc """
  Validates a source snapshot and rejects stale or conflicting collections
  before canonical device records are mutated.

  The activation transaction repeats this check while holding the per-source
  advisory lock. This preflight handles the normal stale/retry path; the
  activation check remains authoritative for concurrent collectors.
  """
  @spec preflight(map(), [map()], map(), keyword()) ::
          {:ok, :process | :idempotent} | {:error, term()}
  def preflight(envelope, updates, context, opts \\ [])

  def preflight(envelope, updates, context, opts) when is_map(envelope) and is_list(updates) do
    if complete_snapshot?(envelope) do
      checker = Keyword.get(opts, :checker, &check_snapshot/1)

      with {:ok, snapshot, _source_devices} <- normalize_snapshot(envelope, updates, context) do
        normalize_preflight_result(checker.(snapshot))
      end
    else
      {:ok, :process}
    end
  rescue
    error ->
      Logger.warning("Device source observation preflight failed: #{Exception.message(error)}")
      {:error, :source_observation_preflight_failed}
  end

  def preflight(_envelope, _updates, _context, _opts), do: {:ok, :process}

  defp normalize_snapshot(envelope, updates, context) do
    metadata = map_value(envelope, "metadata")
    partition = snapshot_partition(updates, context)
    source = string_value(envelope, "source")
    source_instance = string_value(metadata, "source_instance")
    collection_id = string_value(envelope, "collection_id")
    content_hash = string_value(envelope, "reference_hash")
    query_hash = string_value(metadata, "query_hash")
    observed_at = parse_observed_at(string_value(envelope, "observed_at"))

    cond do
      metadata["snapshot_complete"] != true ->
        {:error, :incomplete_source_snapshot}

      not valid_source?(source) ->
        {:error, :invalid_inventory_source}

      not valid_instance?(source_instance) ->
        {:error, :invalid_source_instance}

      not bounded_string?(collection_id, 160) ->
        {:error, :invalid_collection_id}

      not valid_hash?(content_hash) ->
        {:error, :invalid_content_hash}

      query_hash not in [nil, ""] and not valid_hash?(query_hash) ->
        {:error, :invalid_query_hash}

      is_nil(observed_at) ->
        {:error, :invalid_snapshot_timestamp}

      length(updates) > @max_devices ->
        {:error, :source_snapshot_device_limit_exceeded}

      true ->
        snapshot = %{
          partition: partition,
          source: source,
          source_instance: source_instance,
          collection_id: collection_id,
          content_hash: String.downcase(content_hash),
          query_hash: downcase_or_nil(query_hash),
          observed_at: observed_at,
          metadata:
            Map.take(metadata, [
              "page_count",
              "received_rows",
              "unique_devices",
              "invalid_rows",
              "duplicate_rows"
            ])
        }

        with {:ok, devices} <- normalize_source_devices(updates, snapshot),
             true <- unique_source_objects?(devices) do
          {:ok, snapshot, devices}
        else
          false -> {:error, :duplicate_source_object}
          {:error, _} = error -> error
        end
    end
  end

  defp normalize_source_devices(updates, snapshot) do
    updates
    |> Enum.reduce_while({:ok, []}, fn update, {:ok, acc} ->
      case normalize_source_device(update, snapshot) do
        {:ok, device} -> {:cont, {:ok, [device | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, devices} -> {:ok, Enum.reverse(devices)}
      error -> error
    end
  end

  defp validate_resolved_snapshot(snapshot, observations) do
    ids = Enum.map(observations, &Map.get(&1, :source_object_id))

    cond do
      not valid_source?(Map.get(snapshot, :source)) ->
        {:error, :invalid_inventory_source}

      not valid_instance?(Map.get(snapshot, :source_instance)) ->
        {:error, :invalid_source_instance}

      not bounded_string?(Map.get(snapshot, :collection_id), 160) ->
        {:error, :invalid_collection_id}

      not valid_hash?(Map.get(snapshot, :content_hash)) ->
        {:error, :invalid_content_hash}

      not is_struct(Map.get(snapshot, :observed_at), DateTime) ->
        {:error, :invalid_snapshot_timestamp}

      length(observations) > @max_devices ->
        {:error, :source_snapshot_device_limit_exceeded}

      length(ids) != length(Enum.uniq(ids)) ->
        {:error, :duplicate_source_object}

      Enum.any?(observations, &(not valid_resolved_observation?(&1, snapshot))) ->
        {:error, :invalid_resolved_source_observation}

      true ->
        :ok
    end
  end

  defp valid_resolved_observation?(observation, snapshot) do
    is_map(observation) and bounded_string?(Map.get(observation, :device_id), 160) and
      bounded_string?(Map.get(observation, :source_object_id), 160) and
      bounded_string?(Map.get(observation, :source_integration_id), 320) and
      Map.get(observation, :partition) == Map.get(snapshot, :partition) and
      Map.get(observation, :source) == Map.get(snapshot, :source) and
      Map.get(observation, :source_instance) == Map.get(snapshot, :source_instance) and
      Map.get(observation, :collection_id) == Map.get(snapshot, :collection_id)
  end

  defp normalize_source_device(update, snapshot) do
    metadata = map_value(update, "metadata")
    source_object_id = string_value(update, "device_id")
    source_integration_id = string_value(metadata, "integration_id")
    source_metadata = bounded_source_metadata(metadata)

    cond do
      not bounded_string?(source_object_id, 160) ->
        {:error, :invalid_source_object_id}

      not bounded_string?(source_integration_id, 320) or
          not String.starts_with?(source_integration_id, snapshot.source <> ":") ->
        {:error, :invalid_source_integration_id}

      source_metadata == :too_large ->
        {:error, :source_metadata_too_large}

      true ->
        {:ok,
         %{
           partition: snapshot.partition,
           source: snapshot.source,
           source_instance: snapshot.source_instance,
           source_object_id: source_object_id,
           source_integration_id: source_integration_id,
           collection_id: snapshot.collection_id,
           content_hash: snapshot.content_hash,
           query_hash: snapshot.query_hash,
           present: true,
           first_observed_at: snapshot.observed_at,
           last_observed_at: snapshot.observed_at,
           absent_since: nil,
           hostname: bounded_value(update, "hostname", 512),
           ip: bounded_value(update, "ip", 128),
           mac: bounded_value(update, "mac", 256),
           serial_number: bounded_value(metadata, "serial_number", 256),
           vendor_name: bounded_value(metadata, "vendor_name", 256),
           model: bounded_value(metadata, "model", 256),
           device_type: bounded_value(metadata, "device_type", 128),
           site_name: bounded_value(metadata, "site_name", 256),
           management_status: bounded_value(metadata, "status", 128),
           metadata: source_metadata
         }}
    end
  end

  defp bounded_source_metadata(metadata) do
    bounded = map_value(metadata, "source_metadata")

    case {safe_metadata_value?(bounded, 0), Jason.encode(bounded)} do
      {true, {:ok, encoded}} when byte_size(encoded) <= @max_metadata_bytes -> bounded
      _ -> :too_large
    end
  end

  defp safe_metadata_value?(value, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value), do: true

  defp safe_metadata_value?(value, _depth) when is_binary(value), do: byte_size(value) <= 4_096

  defp safe_metadata_value?(value, depth) when is_list(value) and depth < 5 do
    length(value) <= 128 and Enum.all?(value, &safe_metadata_value?(&1, depth + 1))
  end

  defp safe_metadata_value?(value, depth) when is_map(value) and depth < 5 do
    map_size(value) <= 128 and
      Enum.all?(value, fn {key, nested} ->
        is_binary(key) and Regex.match?(@metadata_key_pattern, key) and
          safe_metadata_value?(nested, depth + 1)
      end)
  end

  defp safe_metadata_value?(_value, _depth), do: false

  defp unique_source_objects?(devices) do
    ids = Enum.map(devices, & &1.source_object_id)
    length(ids) == length(Enum.uniq(ids))
  end

  defp resolve_device_ids([], _partition), do: {:ok, %{}}

  defp resolve_device_ids(source_devices, partition) do
    integration_ids = Enum.map(source_devices, & &1.source_integration_id)

    mappings =
      integration_ids
      |> Enum.chunk_every(@lookup_chunk_size)
      |> Enum.flat_map(fn chunk ->
        Repo.all(
          from(identifier in DeviceIdentifier,
            where:
              identifier.identifier_type == :integration_id and
                identifier.identifier_value in ^chunk and identifier.partition == ^partition,
            select: {identifier.identifier_value, identifier.device_id}
          )
        )
      end)
      |> Map.new()

    unresolved = Enum.count(integration_ids, &(not Map.has_key?(mappings, &1)))

    if unresolved == 0,
      do: {:ok, mappings},
      else: {:error, {:unresolved_source_identifiers, unresolved}}
  end

  defp attach_device_ids(source_devices, device_ids) do
    observations =
      Enum.map(source_devices, fn device ->
        Map.put(device, :device_id, Map.get(device_ids, device.source_integration_id))
      end)

    if Enum.any?(observations, &is_nil(&1.device_id)) do
      {:error, :unresolved_source_identifier}
    else
      {:ok, observations}
    end
  end

  defp activate_snapshot(snapshot, observations) do
    case Repo.transaction(fn -> do_activate_snapshot(snapshot, observations) end) do
      {:ok, _stats} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_snapshot(snapshot) do
    current =
      from(source_snapshot in @snapshots_table,
        where:
          source_snapshot.partition == ^snapshot.partition and
            source_snapshot.source == ^snapshot.source and
            source_snapshot.source_instance == ^snapshot.source_instance,
        select: %{
          id: source_snapshot.id,
          collection_id: source_snapshot.collection_id,
          content_hash: source_snapshot.content_hash,
          query_hash: source_snapshot.query_hash,
          observed_at: source_snapshot.observed_at,
          absent_count: source_snapshot.absent_count,
          inserted_at: source_snapshot.inserted_at
        }
      )
      |> Repo.one(prefix: @db_prefix)
      |> normalize_snapshot_row()

    case snapshot_disposition(current, snapshot) do
      :activate -> {:ok, :process}
      :idempotent -> {:ok, :idempotent}
      {:reject, reason} -> {:error, reason}
    end
  end

  defp do_activate_snapshot(snapshot, observations) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    lock_key = Enum.join([snapshot.partition, snapshot.source, snapshot.source_instance], ":")
    _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])

    current =
      from(source_snapshot in @snapshots_table,
        where:
          source_snapshot.partition == ^snapshot.partition and
            source_snapshot.source == ^snapshot.source and
            source_snapshot.source_instance == ^snapshot.source_instance,
        select: %{
          id: source_snapshot.id,
          collection_id: source_snapshot.collection_id,
          content_hash: source_snapshot.content_hash,
          query_hash: source_snapshot.query_hash,
          observed_at: source_snapshot.observed_at,
          absent_count: source_snapshot.absent_count,
          inserted_at: source_snapshot.inserted_at
        },
        lock: "FOR UPDATE"
      )
      |> Repo.one(prefix: @db_prefix)
      |> normalize_snapshot_row()

    case snapshot_disposition(current, snapshot) do
      :idempotent ->
        %{status: :idempotent, absent_count: current.absent_count}

      :activate ->
        records =
          Enum.map(observations, fn observation ->
            observation
            |> Map.put(:id, Ecto.UUID.bingenerate())
            |> Map.put(:inserted_at, now)
            |> Map.put(:updated_at, now)
          end)

        if records != [] do
          Repo.insert_all(@observations_table, records,
            prefix: @db_prefix,
            on_conflict: {:replace, @replace_observation_fields},
            conflict_target: [:partition, :source, :source_instance, :source_object_id]
          )
        end

        {absent_count, _} =
          Repo.update_all(
            from(observation in @observations_table,
              where:
                observation.partition == ^snapshot.partition and
                  observation.source == ^snapshot.source and
                  observation.source_instance == ^snapshot.source_instance and
                  observation.present == true and
                  observation.collection_id != ^snapshot.collection_id
            ),
            [set: [present: false, absent_since: snapshot.observed_at, updated_at: now]],
            prefix: @db_prefix
          )

        snapshot_record = %{
          id: current_id(current),
          partition: snapshot.partition,
          source: snapshot.source,
          source_instance: snapshot.source_instance,
          collection_id: snapshot.collection_id,
          content_hash: snapshot.content_hash,
          query_hash: snapshot.query_hash,
          observed_at: snapshot.observed_at,
          activated_at: now,
          device_count: length(observations),
          absent_count: absent_count,
          metadata: snapshot.metadata,
          inserted_at: current_inserted_at(current, now),
          updated_at: now
        }

        Repo.insert_all(@snapshots_table, [snapshot_record],
          prefix: @db_prefix,
          on_conflict: {:replace, @replace_snapshot_fields},
          conflict_target: [:partition, :source, :source_instance]
        )

        %{status: :activated, absent_count: absent_count}

      {:reject, reason} ->
        Repo.rollback(reason)
    end
  end

  defp snapshot_disposition(nil, _snapshot), do: :activate

  defp snapshot_disposition(current, snapshot) do
    cond do
      current.collection_id == snapshot.collection_id and
        current.content_hash == snapshot.content_hash and
          current.query_hash == snapshot.query_hash ->
        :idempotent

      current.collection_id == snapshot.collection_id ->
        {:reject, :collection_content_mismatch}

      DateTime.before?(snapshot.observed_at, current.observed_at) ->
        {:reject, :stale_source_snapshot}

      true ->
        :activate
    end
  end

  defp current_id(nil), do: Ecto.UUID.bingenerate()
  defp current_id(current), do: current.id
  defp current_inserted_at(nil, now), do: now
  defp current_inserted_at(current, _now), do: current.inserted_at

  defp normalize_snapshot_row(nil), do: nil

  defp normalize_snapshot_row(row) do
    row
    |> Map.update!(:observed_at, &as_utc_datetime/1)
    |> Map.update!(:inserted_at, &as_utc_datetime/1)
  end

  defp as_utc_datetime(nil), do: nil
  defp as_utc_datetime(%DateTime{} = value), do: value

  defp as_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp normalize_activation_result(:ok), do: :ok
  defp normalize_activation_result({:ok, _result}), do: :ok
  defp normalize_activation_result({:error, _reason} = error), do: error
  defp normalize_activation_result(_result), do: {:error, :invalid_snapshot_activation_result}

  defp normalize_preflight_result({:ok, result}) when result in [:process, :idempotent],
    do: {:ok, result}

  defp normalize_preflight_result({:error, _reason} = error), do: error
  defp normalize_preflight_result(_result), do: {:error, :invalid_snapshot_preflight_result}

  defp snapshot_partition([update | _], _context) do
    bounded_value(update, "partition", 128) || "default"
  end

  defp snapshot_partition([], context) do
    bounded_value(context, :partition, 128) || "default"
  end

  defp complete_snapshot?(envelope),
    do: map_value(envelope, "metadata")["snapshot_complete"] == true

  defp parse_observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, _offset} -> DateTime.truncate(observed_at, :microsecond)
      _ -> nil
    end
  end

  defp parse_observed_at(_value), do: nil

  defp map_value(map, key) when is_map(map) do
    value = Map.get(map, key) || alternate_key_value(map, key)
    if is_map(value), do: value, else: %{}
  end

  defp map_value(_map, _key), do: %{}

  defp string_value(map, key) when is_map(map) do
    case Map.get(map, key) || alternate_key_value(map, key) do
      value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp string_value(_map, _key), do: nil

  defp alternate_key_value(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp alternate_key_value(map, key) when is_atom(key), do: Map.get(map, Atom.to_string(key))

  defp bounded_value(map, key, max) do
    case string_value(map, key) do
      value when is_binary(value) and byte_size(value) <= max -> value
      _ -> nil
    end
  end

  defp bounded_string?(value, max),
    do: is_binary(value) and value != "" and byte_size(value) <= max

  defp valid_instance?(value), do: is_binary(value) and Regex.match?(@instance_pattern, value)
  defp valid_source?(value), do: is_binary(value) and Regex.match?(@source_pattern, value)
  defp valid_hash?(value), do: is_binary(value) and Regex.match?(@hash_pattern, value)
  defp downcase_or_nil(nil), do: nil
  defp downcase_or_nil(value), do: String.downcase(value)
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
