defmodule ServiceRadar.EventWriter.Processors.NetFlowMetrics do
  @moduledoc """
  Processor for raw NetFlow/IPFIX metrics from the Rust collector.

  Consumes FlowMessage protobuf messages from `flows.raw.netflow` subject
  and inserts them into the `netflow_metrics` hypertable for network analysis
  and BGP routing visibility.

  ## Message Format

  Binary protobuf `flowpb.FlowMessage` with fields:
  - Basic flow fields (src/dst IP, ports, protocol, bytes, packets)
  - BGP routing information (as_path, bgp_communities)
  - Sampler information
  - Interface details

  ## Difference from NetFlow Processor

  - `NetFlow` processor: Transforms to OCSF format → `ocsf_network_activity` table (security/observability)
  - `NetFlowMetrics` processor: Raw metrics → `netflow_metrics` table (network analysis/BGP visualization)

  ## BGP Fields

  This processor extracts and stores BGP routing information:
  - `as_path`: Array of AS numbers in routing path
  - `bgp_communities`: Array of BGP community values (32-bit format)

  These enable queries like:
  - Find all flows traversing AS 64512: `WHERE as_path @> ARRAY[64512]`
  - Find flows with specific BGP community: `WHERE bgp_communities @> ARRAY[4259840100]`
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias Flowpb.FlowMessage
  alias ServiceRadar.BGP.Ingestor

  require Logger

  @impl true
  def table_name, do: "netflow_metrics"

  @impl true
  def process_batch(messages) do
    # DB connection's search_path determines the schema
    rows = build_rows(messages)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      insert_netflow_metrics_rows(rows)
    end
  rescue
    e ->
      Logger.error("NetFlowMetrics batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  # DB connection's search_path determines the schema
  def parse_message(%{data: data, metadata: metadata}) do
    case FlowMessage.decode(data) do
      {:ok, flow} ->
        parse_flow_message(flow, metadata)

      flow when is_struct(flow, FlowMessage) ->
        parse_flow_message(flow, metadata)

      {:error, reason} ->
        Logger.debug("Failed to decode FlowMessage protobuf: #{inspect(reason)}")
        nil
    end
  rescue
    e ->
      Logger.debug("Exception decoding FlowMessage: #{inspect(e)}")
      nil
  end

  # Private functions

  defp build_rows(messages) do
    messages
    |> Enum.map(&parse_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp insert_netflow_metrics_rows(rows) do
    # DB connection's search_path determines the schema
    {count, _} =
      ServiceRadar.Repo.insert_all(
        table_name(),
        rows,
        on_conflict: :nothing,
        returning: false
      )

    {:ok, count}
  end

  # DB connection's search_path determines the schema
  defp parse_flow_message(flow, _nats_metadata) do
    # Extract timestamp (use flow start time, fallback to received time, fallback to now)
    timestamp = extract_timestamp(flow)

    # Extract IP addresses (convert from binary)
    src_ip = ip_bytes_to_inet(flow.src_addr)
    dst_ip = ip_bytes_to_inet(flow.dst_addr)
    sampler_address = ip_bytes_to_inet(flow.sampler_address)

    # Extract BGP fields (these are already in the right format from the Rust collector)
    as_path = extract_as_path(flow)
    bgp_communities = extract_bgp_communities(flow)

    # Upsert BGP observation if BGP data is present
    bgp_observation_id =
      upsert_bgp_observation(
        timestamp,
        as_path,
        bgp_communities,
        src_ip,
        dst_ip,
        sampler_address,
        normalize_u64(flow.bytes),
        normalize_u64(flow.packets)
      )

    # Build metadata JSON from unmapped fields
    metadata = build_metadata(flow)

    %{
      # Timestamp
      timestamp: timestamp,

      # IP addresses
      src_ip: src_ip,
      dst_ip: dst_ip,
      sampler_address: sampler_address,

      # Ports
      src_port: normalize_port(flow.src_port),
      dst_port: normalize_port(flow.dst_port),

      # Protocol
      protocol: normalize_u32(flow.proto),

      # Traffic statistics
      bytes_total: normalize_u64(flow.bytes),
      packets_total: normalize_u64(flow.packets),

      # BGP routing information (dual-write: old columns + new FK)
      as_path: as_path,
      bgp_communities: bgp_communities,
      bgp_observation_id: bgp_observation_id,

      # Partition (for multi-tenancy)
      partition: "default",

      # Additional metadata
      metadata: metadata
    }
  end

  defp extract_timestamp(flow) do
    cond do
      # Use flow start time if available (nanoseconds -> DateTime)
      flow.time_flow_start_ns > 0 ->
        DateTime.from_unix!(flow.time_flow_start_ns, :nanosecond)

      # Use received time if available
      flow.time_received_ns > 0 ->
        DateTime.from_unix!(flow.time_received_ns, :nanosecond)

      # Fallback to current time
      true ->
        DateTime.utc_now()
    end
  end

  defp ip_bytes_to_inet(nil), do: nil
  defp ip_bytes_to_inet(""), do: nil

  defp ip_bytes_to_inet(bytes) when is_binary(bytes) do
    case byte_size(bytes) do
      4 ->
        # IPv4
        <<a, b, c, d>> = bytes
        %Postgrex.INET{address: {a, b, c, d}, netmask: 32}

      16 ->
        # IPv6
        <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = bytes
        %Postgrex.INET{address: {a, b, c, d, e, f, g, h}, netmask: 128}

      _ ->
        Logger.debug("Invalid IP address length: #{byte_size(bytes)} bytes")
        nil
    end
  rescue
    e ->
      Logger.debug("Failed to convert IP bytes: #{inspect(e)}")
      nil
  end

  defp extract_as_path(flow) do
    case flow.as_path do
      nil ->
        nil

      [] ->
        nil

      path when is_list(path) ->
        # Protobuf gives us uint32 values, but PostgreSQL wants INTEGER (int32)
        # Convert safely, capping at max int32 value
        Enum.map(path, fn asn ->
          min(asn, 2_147_483_647)
        end)
    end
  end

  defp extract_bgp_communities(flow) do
    case flow.bgp_communities do
      nil ->
        nil

      [] ->
        nil

      communities when is_list(communities) ->
        # Protobuf gives us uint32 values, but PostgreSQL wants INTEGER (int32)
        # Convert safely, capping at max int32 value
        Enum.map(communities, fn community ->
          min(community, 2_147_483_647)
        end)
    end
  end

  defp build_metadata(flow) do
    metadata = %{}

    # Add interface information if present
    metadata =
      if flow.in_if > 0 or flow.out_if > 0 do
        Map.merge(metadata, %{
          "in_if" => flow.in_if,
          "out_if" => flow.out_if
        })
      else
        metadata
      end

    # Add observation domain if present
    metadata =
      if flow.observation_domain_id > 0 do
        Map.put(metadata, "observation_domain_id", flow.observation_domain_id)
      else
        metadata
      end

    # Add protocol name if present
    metadata =
      if flow.protocol_name && flow.protocol_name != "" do
        Map.put(metadata, "protocol_name", flow.protocol_name)
      else
        metadata
      end

    # Add VLAN information if present
    metadata =
      if flow.vlan_id > 0 do
        Map.put(metadata, "vlan_id", flow.vlan_id)
      else
        metadata
      end

    # Add sampling rate if present
    metadata =
      if flow.sampling_rate > 0 do
        Map.put(metadata, "sampling_rate", flow.sampling_rate)
      else
        metadata
      end

    # Add TCP flags if present
    metadata =
      if flow.tcp_flags > 0 do
        Map.put(metadata, "tcp_flags", flow.tcp_flags)
      else
        metadata
      end

    # Return nil if empty, otherwise return the metadata map
    if metadata == %{}, do: nil, else: metadata
  end

  defp normalize_u32(0), do: nil
  defp normalize_u32(val) when is_integer(val), do: val
  defp normalize_u32(_), do: nil

  defp normalize_u64(0), do: nil
  defp normalize_u64(val) when is_integer(val), do: val
  defp normalize_u64(_), do: nil

  defp normalize_port(0), do: nil
  defp normalize_port(port) when is_integer(port) and port > 0 and port <= 65_535, do: port
  defp normalize_port(_), do: nil

  # Upsert BGP observation and return observation_id for flow FK
  # Returns nil if no BGP data present or upsert fails
  defp upsert_bgp_observation(
         timestamp,
         as_path,
         bgp_communities,
         src_ip,
         dst_ip,
         sampler_address,
         bytes,
         packets
       ) do
    # Skip if no AS path (required for BGP observation)
    if is_nil(as_path) or as_path == [] do
      nil
    else
      # Convert INET structs to string for BGP observation
      src_ip_str = inet_to_string(src_ip)
      dst_ip_str = inet_to_string(dst_ip)
      sampler_str = inet_to_string(sampler_address)

      # Build BGP observation attributes
      attrs = %{
        timestamp: timestamp,
        source_protocol: "netflow",
        as_path: as_path,
        bgp_communities: bgp_communities,
        src_ip: src_ip_str,
        dst_ip: dst_ip_str,
        bytes: bytes || 0,
        packets: packets || 0,
        metadata: %{sampler_address: sampler_str}
      }

      # Call BGP Ingestor
      case Ingestor.upsert_observation(attrs) do
        {:ok, observation_id} ->
          observation_id

        {:error, reason} ->
          Logger.warning("Failed to upsert BGP observation: #{inspect(reason)}")
          nil
      end
    end
  end

  # Convert Postgrex.INET to string for storage
  defp inet_to_string(nil), do: nil

  defp inet_to_string(%Postgrex.INET{address: address}) do
    address |> :inet.ntoa() |> to_string()
  rescue
    _ -> nil
  end

  defp inet_to_string(_), do: nil
end
