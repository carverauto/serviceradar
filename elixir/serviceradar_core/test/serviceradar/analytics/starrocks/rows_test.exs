defmodule ServiceRadar.Analytics.StarRocks.RowsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.Observability.MtrMetricsIngestor

  @moduletag :db_free

  # 65_533 is the StarRocks events.message VARCHAR limit (priv/starrocks/0004).
  @message_limit 65_533

  defp encode_event(overrides) do
    Map.merge(
      %{
        "id" => "evt-alpha-0001",
        "time" => ~U[2026-09-22 12:00:00Z],
        "class_uid" => 1004,
        "message" => "scan complete",
        "metadata" => %{},
        "unmapped" => %{},
        "device" => %{},
        "observables" => []
      },
      overrides
    )
  end

  test "an oversized message is truncated so the event still lands" do
    message = String.duplicate("x", @message_limit + 100)

    assert [%{"message" => truncated}] =
             Rows.encode(:events, [encode_event(%{"message" => message})])

    assert byte_size(truncated) == @message_limit
    assert String.valid?(truncated)
    assert truncated == String.duplicate("x", @message_limit)
  end

  test "an oversized source is truncated to its 256-byte column limit" do
    source = String.duplicate("s", 300)

    assert [%{"source" => truncated}] =
             Rows.encode(:events, [encode_event(%{"source" => source})])

    assert byte_size(truncated) == 256
  end

  test "a multi-byte value truncates on a UTF-8 boundary rather than mid-codepoint" do
    # 40_000 precomposed "e-acute" is 80_000 bytes; the cut would otherwise
    # fall inside the final codepoint and produce invalid UTF-8.
    message = String.duplicate("é", 40_000)

    assert [%{"message" => truncated}] =
             Rows.encode(:events, [encode_event(%{"message" => message})])

    assert byte_size(truncated) <= @message_limit
    assert String.valid?(truncated)
    assert rem(byte_size(truncated), 2) == 0
  end

  test "a normal event row is unchanged" do
    row = encode_event(%{})

    assert [encoded] = Rows.encode(:events, [row])

    assert encoded["message"] == "scan complete"
    assert encoded["id"] == "evt-alpha-0001"
    assert encoded["metadata"] == "{}"
    assert encoded["observables"] == "[]"
  end

  describe "MTR traces and hops" do
    # A synthetic TCP trace: two hops, the second reporting reply counters,
    # an MPLS label stack and ECMP siblings, both with an AS so no GeoIP
    # lookup runs.
    defp mtr_payload do
      %{
        "results" => [
          %{
            "trace_uuid" => "5e1d2c3b-4a59-4687-9a0b-1c2d3e4f5a6b",
            "check_id" => "check-01",
            "check_name" => "edge path",
            "device_id" => "device-01",
            "target" => "host01.example.com",
            "available" => false,
            "timestamp" => 1_780_000_000,
            "trace" => %{
              "target" => "host01.example.com",
              "target_ip" => "198.51.100.7",
              "total_hops" => 2,
              "protocol" => "tcp",
              "ip_version" => 4,
              "packet_size" => 60,
              "tcp_handshake" => %{"ttl" => 2, "syn_sent" => 3, "synack_received" => 0},
              "hops" => [
                %{
                  "hop_number" => 1,
                  "addr" => "192.0.2.1",
                  "asn" => %{"asn" => 64_500, "org" => "Example Transit"},
                  "sent" => 3,
                  "received" => 3,
                  "loss_pct" => 0.0,
                  "avg_us" => 1_200
                },
                %{
                  "hop_number" => 2,
                  "addr" => "192.0.2.2",
                  "ecmp_addrs" => ["192.0.2.3"],
                  "mpls_labels" => [%{"label" => 16_001, "exp" => 0}],
                  "asn" => %{"asn" => 64_501},
                  "sent" => 3,
                  "received" => 1,
                  "loss_pct" => 66.7,
                  "reply_time_exceeded" => 1
                }
              ]
            }
          }
        ]
      }
    end

    defp mtr_rows do
      {:ok, built} = MtrMetricsIngestor.rows(mtr_payload(), %{agent_id: "agent-01"})
      built
    end

    # The column list of the shipped CREATE, so an encoder that misses or
    # misspells a column fails here rather than loading NULL into it.
    defp ddl_columns(table) do
      create =
        Schema.migrations()
        |> Enum.flat_map(& &1.statements)
        |> Enum.find(&(&1 =~ ~r/^CREATE TABLE IF NOT EXISTS serviceradar\.#{table} \(/))

      ~r/^\s+`?(\w+)`? [A-Z]/m
      |> Regex.scan(create)
      |> Enum.map(&List.last/1)
      |> Enum.sort()
    end

    test "a trace row carries exactly the warehouse columns" do
      [trace] = Rows.encode(:mtr_traces, mtr_rows().traces)

      assert trace |> Map.keys() |> Enum.sort() == ddl_columns("mtr_traces")
      assert trace["id"] == "5e1d2c3b-4a59-4687-9a0b-1c2d3e4f5a6b"
      assert trace["time"] == "2026-05-28T20:26:40Z"
      assert trace["agent_id"] == "agent-01"
      assert trace["target_ip"] == "198.51.100.7"
      assert trace["protocol"] == "tcp"
      assert trace["tcp_syn_sent"] == 3
      assert is_binary(trace["created_at"])
    end

    test "false, zero and absent trace values keep their meaning" do
      [trace] = Rows.encode(:mtr_traces, mtr_rows().traces)

      # `available: false` is a measured miss, not an unknown.
      assert trace["target_reached"] == false
      assert trace["tcp_synack_received"] == 0
      assert trace["gateway_id"] == nil
      assert trace["error"] == nil
      assert trace["tcp_handshake_rtt_avg_us"] == nil
      assert Map.has_key?(trace, "partition")
    end

    test "a hop row carries exactly the warehouse columns, documents and arrays included" do
      [first, second] = Rows.encode(:mtr_hops, mtr_rows().hops)

      assert first |> Map.keys() |> Enum.sort() == ddl_columns("mtr_hops")
      assert first["trace_id"] == "5e1d2c3b-4a59-4687-9a0b-1c2d3e4f5a6b"
      assert first["target_ip"] == "198.51.100.7"
      assert first["device_id"] == "device-01"
      assert first["asn"] == 64_500
      assert first["asn_org"] == "Example Transit"
      assert first["ecmp_addrs"] == []
      assert first["mpls_labels"] == nil
      assert first["avg_us"] == 1_200
      assert first["last_us"] == nil
      assert first["unreachable_code"] == nil
      # The trace reports reply counters, so a hop without one counted zero.
      assert first["reply_time_exceeded"] == 0

      assert second["ecmp_addrs"] == ["192.0.2.3"]
      assert second["mpls_labels"] == %{"labels" => [%{"label" => 16_001, "exp" => 0}]}
      assert second["reply_time_exceeded"] == 1
      assert second["loss_pct"] == 66.7
      assert second["time"] == first["time"]
    end

    test "raw UUID bytes and JSON text are normalized for the load" do
      id = "7b0e6f5c-1d2a-4b3c-8d4e-5f6a7b8c9d0e"

      [hop] =
        Rows.encode(:mtr_hops, [
          %{
            id: Ecto.UUID.dump!(id),
            trace_id: id,
            time: ~U[2026-01-15 10:00:00Z],
            hop_number: 1,
            mpls_labels: ~s({"labels":[{"label":16001}]}),
            ecmp_addrs: nil
          }
        ])

      assert hop["id"] == id
      assert hop["mpls_labels"] == %{"labels" => [%{"label" => 16_001}]}
      assert hop["ecmp_addrs"] == nil
      assert hop["hostname"] == nil
    end

    test "encoded rows survive the Stream Load JSON encoding" do
      built = mtr_rows()

      assert {:ok, _json} = Jason.encode(Rows.encode(:mtr_traces, built.traces))
      assert {:ok, _json} = Jason.encode(Rows.encode(:mtr_hops, built.hops))
    end
  end
end
