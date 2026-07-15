defmodule ServiceRadar.Inventory.SourceInventoryReader do
  @moduledoc """
  Bounded, collection-consistent reads over source-specific device observations.

  This module accepts only fixed typed filters. Cursors bind every page to the
  same activated collection and query shape so callers never combine inventory
  from two source snapshots.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo

  require Logger

  @api_version "v1"
  @schema_version "serviceradar.source_inventory.v1"
  @db_prefix "platform"
  @observations_table "device_source_observations"
  @snapshots_table "device_source_snapshots"
  @default_limit 100
  @max_limit 500
  @max_cursor_bytes 1_024
  @allowed_params ~w(collection cursor instance limit partition presence source)
  @source_pattern ~r/^[a-z0-9][a-z0-9_.-]{0,127}$/
  @instance_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
  @opaque_id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$/
  @presence_values ~w(present absent all)
  @cursor_keys ~w(collection id instance last_observed_at partition presence source v)

  @type error_reason ::
          {:invalid_query, atom()}
          | :source_collection_changed
          | :source_snapshot_not_found
          | :source_inventory_unavailable

  @spec list(map()) :: {:ok, map()} | {:error, error_reason()}
  def list(params) when is_map(params) do
    with {:ok, opts} <- parse_params(params) do
      case Repo.transaction(fn -> read_page(opts) end) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, :source_inventory_unavailable}
      end
    end
  rescue
    error ->
      Logger.error("Source inventory read failed with #{inspect(error.__struct__)}")
      {:error, :source_inventory_unavailable}
  end

  def list(_params), do: {:error, {:invalid_query, :invalid_query_params}}

  @doc false
  @spec parse_params(map()) :: {:ok, map()} | {:error, {:invalid_query, atom()}}
  def parse_params(params) when is_map(params) do
    with :ok <- reject_unknown_params(params),
         {:ok, source} <- parse_source(Map.get(params, "source")),
         {:ok, instance} <-
           parse_required_identifier(Map.get(params, "instance"), @instance_pattern),
         {:ok, partition} <- parse_partition(Map.get(params, "partition")),
         {:ok, presence} <- parse_presence(Map.get(params, "presence")),
         {:ok, collection} <- parse_optional_identifier(Map.get(params, "collection")),
         {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, cursor} <- decode_cursor(Map.get(params, "cursor")),
         :ok <- validate_cursor_context(cursor, source, instance, partition, presence, collection) do
      {:ok,
       %{
         source: source,
         instance: instance,
         partition: partition,
         presence: presence,
         collection: collection,
         limit: limit,
         cursor: cursor
       }}
    end
  end

  def parse_params(_params), do: {:error, {:invalid_query, :invalid_query_params}}

  @doc false
  @spec decode_cursor(nil | String.t()) :: {:ok, nil | map()} | {:error, {:invalid_query, atom()}}
  def decode_cursor(nil), do: {:ok, nil}
  def decode_cursor(""), do: {:ok, nil}

  def decode_cursor(value) when is_binary(value) and byte_size(value) <= @max_cursor_bytes do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, cursor} when is_map(cursor) <- Jason.decode(decoded),
         :ok <- validate_cursor_keys(cursor),
         1 <- cursor["v"],
         {:ok, source} <- parse_source(cursor["source"]),
         {:ok, instance} <- parse_required_identifier(cursor["instance"], @instance_pattern),
         {:ok, partition} <- parse_partition(cursor["partition"]),
         {:ok, presence} <- parse_presence(cursor["presence"]),
         {:ok, collection} <- parse_required_identifier(cursor["collection"], @opaque_id_pattern),
         {:ok, observed_at, 0} <- DateTime.from_iso8601(cursor["last_observed_at"]),
         {:ok, id} <- Ecto.UUID.cast(cursor["id"]),
         {:ok, binary_id} <- Ecto.UUID.dump(id) do
      {:ok,
       %{
         source: source,
         instance: instance,
         partition: partition,
         presence: presence,
         collection: collection,
         last_observed_at: DateTime.truncate(observed_at, :microsecond),
         id: binary_id
       }}
    else
      _ -> {:error, {:invalid_query, :invalid_cursor}}
    end
  end

  def decode_cursor(_value), do: {:error, {:invalid_query, :invalid_cursor}}

  defp read_page(opts) do
    case current_snapshot(opts) do
      nil ->
        {:error, :source_snapshot_not_found}

      snapshot ->
        with :ok <- ensure_current_collection(opts, snapshot),
             rows = observation_page(opts, snapshot.collection_id),
             :ok <- ensure_snapshot_unchanged(snapshot, current_snapshot(opts)) do
          {:ok, response(opts, snapshot, rows)}
        end
    end
  end

  defp current_snapshot(opts) do
    from(snapshot in @snapshots_table,
      where:
        snapshot.partition == ^opts.partition and snapshot.source == ^opts.source and
          snapshot.source_instance == ^opts.instance,
      select: %{
        collection_id: snapshot.collection_id,
        content_hash: snapshot.content_hash,
        query_hash: snapshot.query_hash,
        observed_at: snapshot.observed_at,
        activated_at: snapshot.activated_at,
        device_count: snapshot.device_count,
        absent_count: snapshot.absent_count
      }
    )
    |> Repo.one(prefix: @db_prefix)
    |> normalize_snapshot_row()
  end

  defp ensure_current_collection(opts, snapshot) do
    expected = cursor_collection(opts.cursor) || opts.collection

    if is_nil(expected) or expected == snapshot.collection_id,
      do: :ok,
      else: {:error, :source_collection_changed}
  end

  defp ensure_snapshot_unchanged(snapshot, current) do
    if current && current.collection_id == snapshot.collection_id &&
         current.content_hash == snapshot.content_hash &&
         current.query_hash == snapshot.query_hash,
       do: :ok,
       else: {:error, :source_collection_changed}
  end

  defp observation_page(opts, current_collection) do
    @observations_table
    |> base_observation_query(opts)
    |> filter_presence(opts.presence, current_collection)
    |> filter_cursor(opts.cursor)
    |> limit(^(opts.limit + 1))
    |> Repo.all(prefix: @db_prefix)
    |> Enum.map(&normalize_observation_row/1)
  end

  defp base_observation_query(queryable, opts) do
    from(observation in queryable,
      left_join: device in Device,
      on: device.uid == observation.device_id and is_nil(device.deleted_at),
      where:
        observation.partition == ^opts.partition and observation.source == ^opts.source and
          observation.source_instance == ^opts.instance,
      order_by: [desc: observation.last_observed_at, asc: observation.id],
      select: %{
        cursor_id: observation.id,
        canonical_device_uid: observation.device_id,
        source: observation.source,
        source_instance: observation.source_instance,
        source_object_id: observation.source_object_id,
        source_integration_id: observation.source_integration_id,
        collection_id: observation.collection_id,
        present: observation.present,
        first_observed_at: observation.first_observed_at,
        last_observed_at: observation.last_observed_at,
        absent_since: observation.absent_since,
        hostname: observation.hostname,
        ip: observation.ip,
        mac: observation.mac,
        serial_number: observation.serial_number,
        vendor_name: observation.vendor_name,
        model: observation.model,
        device_type: observation.device_type,
        partition: observation.site_name,
        management_status: observation.management_status,
        metadata: observation.metadata,
        canonical_hostname: device.hostname,
        canonical_ip: device.ip,
        canonical_mac: device.mac,
        canonical_vendor_name: device.vendor_name,
        canonical_model: device.model,
        canonical_discovery_sources: device.discovery_sources
      }
    )
  end

  defp filter_presence(query, "present", collection_id) do
    where(
      query,
      [observation, _device],
      observation.present == true and observation.collection_id == ^collection_id
    )
  end

  defp filter_presence(query, "absent", _collection_id) do
    where(query, [observation, _device], observation.present == false)
  end

  defp filter_presence(query, "all", _collection_id), do: query

  defp filter_cursor(query, nil), do: query

  defp filter_cursor(query, cursor) do
    where(
      query,
      [observation, _device],
      observation.last_observed_at < ^cursor.last_observed_at or
        (observation.last_observed_at == ^cursor.last_observed_at and observation.id > ^cursor.id)
    )
  end

  defp response(opts, snapshot, fetched_rows) do
    has_more = length(fetched_rows) > opts.limit
    rows = Enum.take(fetched_rows, opts.limit)

    %{
      "api_version" => @api_version,
      "schema_version" => @schema_version,
      "source" => opts.source,
      "source_instance" => opts.instance,
      "partition" => opts.partition,
      "collection" => %{
        "id" => snapshot.collection_id,
        "content_hash" => snapshot.content_hash,
        "query_hash" => snapshot.query_hash,
        "observed_at" => iso8601(snapshot.observed_at),
        "completed_at" => iso8601(snapshot.activated_at),
        "expected_present_count" => snapshot.device_count,
        "absent_count" => snapshot.absent_count,
        "complete" => true
      },
      "rows" => Enum.map(rows, &serialize_row/1),
      "pagination" => %{
        "limit" => opts.limit,
        "has_more" => has_more,
        "next_cursor" => next_cursor(rows, opts, snapshot.collection_id, has_more)
      }
    }
  end

  defp serialize_row(row) do
    %{
      "canonical_device_uid" => row.canonical_device_uid,
      "source" => row.source,
      "source_instance" => row.source_instance,
      "source_object_id" => row.source_object_id,
      "source_integration_id" => row.source_integration_id,
      "collection_id" => row.collection_id,
      "present" => row.present,
      "first_observed_at" => iso8601(row.first_observed_at),
      "last_observed_at" => iso8601(row.last_observed_at),
      "absent_since" => iso8601(row.absent_since),
      "hostname" => row.hostname,
      "ip" => row.ip,
      "mac" => row.mac,
      "serial_number" => row.serial_number,
      "vendor_name" => row.vendor_name,
      "model" => row.model,
      "device_type" => row.device_type,
      "partition" => row.partition,
      "management_status" => row.management_status,
      "metadata" => row.metadata || %{},
      "canonical" => %{
        "hostname" => row.canonical_hostname,
        "ip" => row.canonical_ip,
        "mac" => row.canonical_mac,
        "vendor_name" => row.canonical_vendor_name,
        "model" => row.canonical_model,
        "discovery_sources" => row.canonical_discovery_sources || []
      }
    }
  end

  defp next_cursor(_rows, _opts, _collection, false), do: nil

  defp next_cursor(rows, opts, collection, true) do
    row = List.last(rows)

    %{
      "v" => 1,
      "source" => opts.source,
      "instance" => opts.instance,
      "partition" => opts.partition,
      "presence" => opts.presence,
      "collection" => collection,
      "last_observed_at" => iso8601(row.last_observed_at),
      "id" => Ecto.UUID.load!(row.cursor_id)
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp reject_unknown_params(params) do
    unknown = Map.keys(params) -- @allowed_params
    if unknown == [], do: :ok, else: {:error, {:invalid_query, :unknown_query_parameter}}
  end

  defp parse_source(nil), do: {:error, {:invalid_query, :source_required}}

  defp parse_source(value) when is_binary(value) do
    source = value |> String.trim() |> String.downcase()
    if Regex.match?(@source_pattern, source), do: {:ok, source}, else: invalid_identifier()
  end

  defp parse_source(_value), do: invalid_identifier()

  defp parse_partition(nil), do: {:ok, "default"}
  defp parse_partition(value), do: parse_required_identifier(value, @instance_pattern)

  defp parse_presence(nil), do: {:ok, "present"}

  defp parse_presence(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if normalized in @presence_values,
      do: {:ok, normalized},
      else: {:error, {:invalid_query, :invalid_presence}}
  end

  defp parse_presence(_value), do: {:error, {:invalid_query, :invalid_presence}}

  defp parse_optional_identifier(nil), do: {:ok, nil}
  defp parse_optional_identifier(""), do: {:ok, nil}
  defp parse_optional_identifier(value), do: parse_required_identifier(value, @opaque_id_pattern)

  defp parse_required_identifier(value, pattern) when is_binary(value) do
    normalized = String.trim(value)
    if Regex.match?(pattern, normalized), do: {:ok, normalized}, else: invalid_identifier()
  end

  defp parse_required_identifier(_value, _pattern), do: invalid_identifier()

  defp invalid_identifier, do: {:error, {:invalid_query, :invalid_identifier}}

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parse_limit(parsed)
      _ -> {:error, {:invalid_query, :invalid_limit}}
    end
  end

  defp parse_limit(value) when is_integer(value) and value > 0 and value <= @max_limit,
    do: {:ok, value}

  defp parse_limit(_value), do: {:error, {:invalid_query, :invalid_limit}}

  defp validate_cursor_keys(cursor) do
    if cursor |> Map.keys() |> Enum.sort() == @cursor_keys,
      do: :ok,
      else: {:error, :invalid_cursor_keys}
  end

  defp validate_cursor_context(nil, _source, _instance, _partition, _presence, _collection),
    do: :ok

  defp validate_cursor_context(cursor, source, instance, partition, presence, collection) do
    matches_query =
      cursor.source == source and cursor.instance == instance and cursor.partition == partition and
        cursor.presence == presence

    matches_collection = is_nil(collection) or collection == cursor.collection

    if matches_query and matches_collection,
      do: :ok,
      else: {:error, {:invalid_query, :cursor_query_mismatch}}
  end

  defp cursor_collection(nil), do: nil
  defp cursor_collection(cursor), do: cursor.collection

  defp normalize_snapshot_row(nil), do: nil

  defp normalize_snapshot_row(row) do
    row
    |> Map.update!(:observed_at, &as_utc_datetime/1)
    |> Map.update!(:activated_at, &as_utc_datetime/1)
  end

  defp normalize_observation_row(row) do
    Enum.reduce([:first_observed_at, :last_observed_at, :absent_since], row, fn key, acc ->
      Map.update!(acc, key, &as_utc_datetime/1)
    end)
  end

  defp as_utc_datetime(nil), do: nil
  defp as_utc_datetime(%DateTime{} = value), do: value

  defp as_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
