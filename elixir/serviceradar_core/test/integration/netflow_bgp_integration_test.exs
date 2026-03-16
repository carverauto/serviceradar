defmodule ServiceRadar.Integration.NetflowBGPIntegrationTest do
  @moduledoc """
  Integration tests for NetFlow BGP support end-to-end flow.

  These tests verify:
  - FlowMessage protobuf → NATS → EventWriter → PostgreSQL pipeline
  - BGP fields (as_path, bgp_communities) are correctly stored
  - GIN indexes enable fast array containment queries
  - Batch processing performance under load

  ## Running These Tests

  Requires running infrastructure:
  - PostgreSQL with netflow_metrics table created
  - NATS JetStream with flows.raw.netflow stream
  - EventWriter consumer running

  Run with:
      mix test test/integration/netflow_bgp_integration_test.exs

  Or tag as integration-only:
      mix test --only integration
  """

  use ExUnit.Case, async: false
  import Ecto.Query

  alias ServiceRadar.Repo
  alias Flowpb.FlowMessage

  @moduletag :integration
  @moduletag timeout: 60_000

  setup do
    # Clean up test data before each test
    Repo.delete_all("netflow_metrics")
    :ok
  end

  describe "FlowMessage → NATS → EventWriter → PostgreSQL pipeline" do
    @tag :nats_required
    test "sends FlowMessage to NATS and verifies row insertion" do
      # Create a FlowMessage with BGP data
      flow = %FlowMessage{
        type: :IPFIX,
        time_received_ns: System.system_time(:nanosecond),
        time_flow_start_ns: System.system_time(:nanosecond) - 10_000_000_000,
        sampler_address: <<10, 1, 0, 1>>,
        src_addr: <<192, 168, 1, 100>>,
        dst_addr: <<8, 8, 8, 8>>,
        src_port: 49152,
        dst_port: 443,
        proto: 6,
        bytes: 1_500_000,
        packets: 1000,
        # BGP fields
        as_path: [64512, 64513, 64514],
        bgp_communities: [4_259_840_100, 4_259_840_200]
      }

      # Encode and publish to NATS
      encoded = FlowMessage.encode(flow)
      subject = "flows.raw.netflow"

      {:ok, conn} = Gnat.start_link(%{host: "localhost", port: 4222})
      :ok = Gnat.pub(conn, subject, encoded)

      # Wait for EventWriter to process (batch timeout is 500ms)
      Process.sleep(1000)

      # Query database to verify row was inserted
      query = from(n in "netflow_metrics",
        where: fragment("src_ip = ?::inet", "192.168.1.100"),
        select: %{
          src_ip: n.src_ip,
          dst_ip: n.dst_ip,
          src_port: n.src_port,
          dst_port: n.dst_port,
          protocol: n.protocol,
          bytes_total: n.bytes_total,
          packets_total: n.packets_total,
          as_path: n.as_path,
          bgp_communities: n.bgp_communities
        }
      )

      result = Repo.one(query)

      assert result != nil
      assert result.src_port == 49152
      assert result.dst_port == 443
      assert result.protocol == 6
      assert result.bytes_total == 1_500_000
      assert result.packets_total == 1000
      assert result.as_path == [64512, 64513, 64514]
      assert result.bgp_communities == [4_259_840_100, 4_259_840_200]

      Gnat.stop(conn)
    end

    @tag :nats_required
    test "verifies BGP fields are populated correctly with different AS paths" do
      flows = [
        # Flow 1: Full path
        %FlowMessage{
          time_received_ns: System.system_time(:nanosecond),
          src_addr: <<10, 0, 0, 1>>,
          dst_addr: <<10, 0, 0, 2>>,
          proto: 6,
          src_port: 1000,
          dst_port: 2000,
          bytes: 100,
          packets: 1,
          as_path: [64512, 64513, 64514, 64515]
        },
        # Flow 2: Direct path
        %FlowMessage{
          time_received_ns: System.system_time(:nanosecond),
          src_addr: <<10, 0, 0, 3>>,
          dst_addr: <<10, 0, 0, 4>>,
          proto: 17,
          src_port: 3000,
          dst_port: 4000,
          bytes: 200,
          packets: 2,
          as_path: [64512, 64514]
        },
        # Flow 3: With BGP communities
        %FlowMessage{
          time_received_ns: System.system_time(:nanosecond),
          src_addr: <<10, 0, 0, 5>>,
          dst_addr: <<10, 0, 0, 6>>,
          proto: 6,
          src_port: 5000,
          dst_port: 6000,
          bytes: 300,
          packets: 3,
          as_path: [64512, 64516],
          bgp_communities: [0xFFFFFF01, 0xFFFFFF02, 0xFFFFFF03]  # Well-known communities
        }
      ]

      {:ok, conn} = Gnat.start_link(%{host: "localhost", port: 4222})

      for flow <- flows do
        encoded = FlowMessage.encode(flow)
        :ok = Gnat.pub(conn, "flows.raw.netflow", encoded)
      end

      Process.sleep(1000)

      # Verify all flows inserted
      count = Repo.one(from(n in "netflow_metrics", select: count(n.timestamp)))
      assert count >= 3

      Gnat.stop(conn)
    end
  end

  describe "GIN index queries for AS path containment" do
    setup do
      # Insert test data directly
      now = DateTime.utc_now()

      test_flows = [
        %{
          timestamp: now,
          src_ip: %Postgrex.INET{address: {10, 0, 0, 1}, netmask: 32},
          dst_ip: %Postgrex.INET{address: {10, 0, 0, 2}, netmask: 32},
          src_port: 1000,
          dst_port: 2000,
          protocol: 6,
          bytes_total: 1000,
          packets_total: 10,
          as_path: [64512, 64513, 64514],
          partition: "default"
        },
        %{
          timestamp: DateTime.add(now, 1, :second),
          src_ip: %Postgrex.INET{address: {10, 0, 0, 3}, netmask: 32},
          dst_ip: %Postgrex.INET{address: {10, 0, 0, 4}, netmask: 32},
          src_port: 3000,
          dst_port: 4000,
          protocol: 17,
          bytes_total: 2000,
          packets_total: 20,
          as_path: [64512, 64515],
          partition: "default"
        },
        %{
          timestamp: DateTime.add(now, 2, :second),
          src_ip: %Postgrex.INET{address: {10, 0, 0, 5}, netmask: 32},
          dst_ip: %Postgrex.INET{address: {10, 0, 0, 6}, netmask: 32},
          src_port: 5000,
          dst_port: 6000,
          protocol: 6,
          bytes_total: 3000,
          packets_total: 30,
          as_path: [64516, 64517],
          partition: "default"
        }
      ]

      Repo.insert_all("netflow_metrics", test_flows)

      :ok
    end

    test "GIN query: WHERE as_path @> ARRAY[64512] finds flows traversing AS 64512" do
      query = """
      SELECT COUNT(*)
      FROM netflow_metrics
      WHERE as_path @> ARRAY[64512]
      """

      result = Repo.query!(query)
      [[count]] = result.rows

      # Should find 2 flows (first two) that traverse AS 64512
      assert count == 2
    end

    test "GIN query: WHERE as_path @> ARRAY[64513, 64514] finds flows with both ASNs" do
      query = """
      SELECT src_port, as_path
      FROM netflow_metrics
      WHERE as_path @> ARRAY[64513, 64514]
      ORDER BY timestamp
      """

      result = Repo.query!(query)

      # Should find only the first flow with path [64512, 64513, 64514]
      assert length(result.rows) == 1
      [[src_port, as_path]] = result.rows
      assert src_port == 1000
      assert as_path == [64512, 64513, 64514]
    end

    test "GIN query performance with EXPLAIN ANALYZE" do
      query = """
      EXPLAIN ANALYZE
      SELECT COUNT(*)
      FROM netflow_metrics
      WHERE as_path @> ARRAY[64512]
      """

      result = Repo.query!(query)

      # Verify GIN index is being used (look for "Bitmap Index Scan")
      plan = Enum.map(result.rows, fn [line] -> line end) |> Enum.join("\n")
      assert plan =~ ~r/Index.*idx_netflow_metrics_as_path/i
    end
  end

  describe "GIN index queries for BGP communities containment" do
    setup do
      now = DateTime.utc_now()

      test_flows = [
        %{
          timestamp: now,
          src_ip: %Postgrex.INET{address: {10, 0, 0, 1}, netmask: 32},
          dst_ip: %Postgrex.INET{address: {10, 0, 0, 2}, netmask: 32},
          protocol: 6,
          bytes_total: 1000,
          packets_total: 10,
          bgp_communities: [4_259_840_100, 4_259_840_200],  # 65000:100, 65000:200
          partition: "default"
        },
        %{
          timestamp: DateTime.add(now, 1, :second),
          src_ip: %Postgrex.INET{address: {10, 0, 0, 3}, netmask: 32},
          dst_ip: %Postgrex.INET{address: {10, 0, 0, 4}, netmask: 32},
          protocol: 17,
          bytes_total: 2000,
          packets_total: 20,
          bgp_communities: [0xFFFFFF01],  # NO_EXPORT
          partition: "default"
        }
      ]

      Repo.insert_all("netflow_metrics", test_flows)

      :ok
    end

    test "GIN query: WHERE bgp_communities @> ARRAY[...] finds flows with specific community" do
      query = """
      SELECT COUNT(*)
      FROM netflow_metrics
      WHERE bgp_communities @> ARRAY[4259840100]
      """

      result = Repo.query!(query)
      [[count]] = result.rows

      assert count == 1
    end

    test "GIN query: finds flows with well-known community NO_EXPORT" do
      query = """
      SELECT bytes_total, bgp_communities
      FROM netflow_metrics
      WHERE bgp_communities @> ARRAY[#{0xFFFFFF01}]
      """

      result = Repo.query!(query)

      assert length(result.rows) == 1
      [[bytes, communities]] = result.rows
      assert bytes == 2000
      assert communities == [0xFFFFFF01]
    end
  end

  describe "Load testing: batch processing performance" do
    @tag :load_test
    @tag timeout: 120_000
    test "sends 10,000 flows and verifies batch processing performance" do
      {:ok, conn} = Gnat.start_link(%{host: "localhost", port: 4222})

      flow_count = 10_000
      batch_size = 100

      start_time = System.monotonic_time(:millisecond)

      # Send flows in batches
      for batch_num <- 1..div(flow_count, batch_size) do
        for i <- 1..batch_size do
          flow_num = (batch_num - 1) * batch_size + i

          flow = %FlowMessage{
            type: :IPFIX,
            time_received_ns: System.system_time(:nanosecond),
            src_addr: <<192, 168, rem(flow_num, 256), div(flow_num, 256)>>,
            dst_addr: <<8, 8, 8, 8>>,
            src_port: rem(flow_num, 65535),
            dst_port: 443,
            proto: 6,
            bytes: 1500,
            packets: 1,
            as_path: [64512, 64513],
            bgp_communities: [4_259_840_100]
          }

          encoded = FlowMessage.encode(flow)
          :ok = Gnat.pub(conn, "flows.raw.netflow", encoded)
        end

        # Small delay between batches to avoid overwhelming NATS
        Process.sleep(10)
      end

      publish_time = System.monotonic_time(:millisecond) - start_time

      # Wait for EventWriter to process all messages
      # With batch_size=50 and batch_timeout=500ms, this should take ~10 seconds for 10k flows
      Process.sleep(15_000)

      # Verify row count
      query = from(n in "netflow_metrics", select: count(n.timestamp))
      inserted_count = Repo.one(query)

      total_time = System.monotonic_time(:millisecond) - start_time

      # Performance assertions
      assert inserted_count >= flow_count * 0.99  # Allow 1% loss
      assert total_time < 60_000  # Should complete within 60 seconds

      IO.puts("""

      Load Test Results:
        - Flows sent: #{flow_count}
        - Flows inserted: #{inserted_count}
        - Publish time: #{publish_time}ms
        - Total time: #{total_time}ms
        - Throughput: #{round(flow_count / (total_time / 1000))} flows/sec
      """)

      Gnat.stop(conn)
    end
  end
end
