defmodule ServiceRadar.BGP.Ingestor do
  @moduledoc """
  BGP observation ingestion with protocol-agnostic interface.

  Handles upsert logic for BGP observations with deduplication and aggregation.
  Supports multiple data sources (NetFlow, sFlow, BMP) writing to common schema.

  ## Usage

      # Single observation
      {:ok, observation_id} = Ingestor.upsert_observation(%{
        timestamp: ~U[2026-02-15 12:00:00Z],
        source_protocol: "netflow",
        as_path: [64512, 64513, 8075],
        bgp_communities: [6553800, 4294967041],
        src_ip: "192.168.1.100",
        dst_ip: "8.8.8.8",
        bytes: 1500,
        packets: 1,
        metadata: %{sampler_address: "10.0.1.1"}
      })

      # Batch observations
      {:ok, observation_ids} = Ingestor.batch_upsert_observations([...])

  ## Deduplication

  Observations are deduplicated on (time_bucket(1 minute), source_protocol,
  as_path, communities, src_ip, dst_ip). Multiple observations with the same
  key increment aggregation columns (total_bytes, total_packets, flow_count).

  ## PubSub Notifications

  Broadcasts to Phoenix.PubSub "bgp:observations" topic on create/update:
  - `{:bgp_observation, :created, observation_id, metadata}`
  - `{:bgp_observation, :updated, observation_id, metadata}`
  """

  alias ServiceRadar.Repo

  require Logger

  @max_batch_size 1000

  @doc """
  Upsert a single BGP observation.

  ## Parameters
    * `attrs` - Map with observation attributes:
      - `timestamp` (required) - DateTime
      - `source_protocol` (required) - "netflow" | "sflow" | "bgp_peering"
      - `as_path` (required) - List of AS numbers [integer]
      - `bgp_communities` (optional) - List of community values [integer]
      - `src_ip` (optional) - Source IP address string
      - `dst_ip` (optional) - Destination IP address string
      - `bytes` (optional) - Bytes for this observation (default: 0)
      - `packets` (optional) - Packets for this observation (default: 0)
      - `metadata` (optional) - Additional context map

  ## Returns
    * `{:ok, observation_id}` - UUID of created/updated observation
    * `{:error, reason}` - Validation or database error

  ## Examples

      iex> upsert_observation(%{
      ...>   timestamp: ~U[2026-02-15 12:00:00Z],
      ...>   source_protocol: "netflow",
      ...>   as_path: [64512, 8075],
      ...>   bytes: 1000
      ...> })
      {:ok, "550e8400-e29b-41d4-a716-446655440000"}
  """
  def upsert_observation(attrs) do
    with :ok <- validate_observation(attrs),
         {:ok, bucketed_attrs} <- bucket_timestamp(attrs),
         {:ok, observation_id} <- do_upsert(bucketed_attrs) do
      broadcast_observation(:created, observation_id, bucketed_attrs)
      {:ok, observation_id}
    end
  end

  @doc """
  Batch upsert multiple BGP observations.

  Processes up to #{@max_batch_size} observations per transaction.
  Larger batches are automatically split.

  ## Parameters
    * `observations` - List of observation attribute maps

  ## Returns
    * `{:ok, [observation_ids]}` - List of UUIDs
    * `{:error, reason}` - If batch fails

  ## Examples

      iex> batch_upsert_observations([
      ...>   %{timestamp: ~U[...], source_protocol: "netflow", as_path: [64512, 8075]},
      ...>   %{timestamp: ~U[...], source_protocol: "netflow", as_path: [64512, 15169]}
      ...> ])
      {:ok, ["uuid1", "uuid2"]}
  """
  def batch_upsert_observations(observations) when is_list(observations) do
    observations
    |> Enum.chunk_every(@max_batch_size)
    |> Enum.reduce({:ok, []}, fn batch, {:ok, acc_ids} ->
      case process_batch(batch) do
        {:ok, ids} -> {:ok, acc_ids ++ ids}
        {:error, _} = error -> error
      end
    end)
  end

  # Private functions

  defp validate_observation(attrs) do
    with :ok <- validate_source_protocol(attrs[:source_protocol]),
         :ok <- validate_as_path(attrs[:as_path]) do
      validate_bgp_communities(attrs[:bgp_communities])
    end
  end

  defp validate_source_protocol(protocol) when protocol in ["netflow", "sflow", "bgp_peering"],
    do: :ok

  defp validate_source_protocol(nil), do: {:error, "source_protocol is required"}

  defp validate_source_protocol(protocol),
    do: {:error, "Invalid source_protocol: #{protocol}. Must be netflow, sflow, or bgp_peering"}

  defp validate_as_path([_ | _] = as_path) do
    if Enum.all?(as_path, &valid_as_number?/1) do
      :ok
    else
      {:error, "AS path contains invalid AS numbers (must be 1-4294967295)"}
    end
  end

  defp validate_as_path([]), do: {:error, "AS path cannot be empty"}
  defp validate_as_path(nil), do: {:error, "AS path is required"}
  defp validate_as_path(_), do: {:error, "AS path must be a list of integers"}

  defp validate_bgp_communities(nil), do: :ok
  defp validate_bgp_communities([]), do: :ok

  defp validate_bgp_communities(communities) when is_list(communities) do
    if Enum.all?(communities, &valid_community?/1) do
      :ok
    else
      {:error, "BGP communities contain invalid values (must be 0-4294967295)"}
    end
  end

  defp validate_bgp_communities(_), do: {:error, "BGP communities must be a list of integers"}

  defp valid_as_number?(as) when is_integer(as) and as >= 1 and as <= 4_294_967_295, do: true
  defp valid_as_number?(_), do: false

  defp valid_community?(c) when is_integer(c) and c >= 0 and c <= 4_294_967_295, do: true
  defp valid_community?(_), do: false

  defp bucket_timestamp(attrs) do
    timestamp = attrs[:timestamp] || DateTime.utc_now()

    # Bucket to 1-minute intervals
    bucketed =
      timestamp
      |> DateTime.truncate(:second)
      |> then(fn dt ->
        %{dt | second: 0, microsecond: {0, 6}}
      end)

    {:ok, Map.put(attrs, :timestamp, bucketed)}
  end

  defp do_upsert(attrs) do
    # Build INSERT with ON CONFLICT DO UPDATE
    bytes = attrs[:bytes] || 0
    packets = attrs[:packets] || 0
    flow_count = 1

    query = """
    INSERT INTO platform.bgp_routing_info (
      id,
      timestamp,
      source_protocol,
      as_path,
      bgp_communities,
      src_ip,
      dst_ip,
      total_bytes,
      total_packets,
      flow_count,
      metadata,
      created_at
    ) VALUES (
      gen_random_uuid(),
      $1,
      $2,
      $3,
      $4,
      $5,
      $6,
      $7,
      $8,
      $9,
      $10,
      NOW()
    )
    ON CONFLICT ON CONSTRAINT idx_bgp_routing_dedup
    DO UPDATE SET
      total_bytes = bgp_routing_info.total_bytes + EXCLUDED.total_bytes,
      total_packets = bgp_routing_info.total_packets + EXCLUDED.total_packets,
      flow_count = bgp_routing_info.flow_count + EXCLUDED.flow_count
    RETURNING id
    """

    params = [
      attrs[:timestamp],
      attrs[:source_protocol],
      attrs[:as_path],
      attrs[:bgp_communities] || [],
      attrs[:src_ip],
      attrs[:dst_ip],
      bytes,
      packets,
      flow_count,
      attrs[:metadata] || %{}
    ]

    case Repo.query(query, params) do
      {:ok, %{rows: [[id]]}} ->
        {:ok, id}

      {:error, %Postgrex.Error{} = error} ->
        Logger.error("BGP observation upsert failed: #{inspect(error)}")
        {:error, :database_error}

      {:error, reason} ->
        Logger.error("BGP observation upsert failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_batch(observations) do
    Repo.transaction(fn ->
      Enum.map(observations, &upsert_observation!/1)
    end)
  end

  defp upsert_observation!(obs) do
    case upsert_observation(obs) do
      {:ok, id} -> id
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp broadcast_observation(action, observation_id, attrs) do
    metadata = %{
      observation_id: observation_id,
      source_protocol: attrs[:source_protocol],
      as_path: attrs[:as_path],
      added_bytes: attrs[:bytes] || 0
    }

    Phoenix.PubSub.broadcast(
      ServiceRadarWebNG.PubSub,
      "bgp:observations",
      {:bgp_observation, action, observation_id, metadata}
    )
  rescue
    error ->
      Logger.warning("Failed to broadcast BGP observation: #{inspect(error)}")
      :ok
  end
end
