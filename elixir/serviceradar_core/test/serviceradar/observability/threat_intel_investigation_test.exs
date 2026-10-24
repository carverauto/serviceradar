defmodule ServiceRadar.Observability.ThreatIntelInvestigationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ThreatIntelEvidence
  alias ServiceRadar.Observability.ThreatIntelInvestigation
  alias ServiceRadar.Observability.ThreatIntelInvestigation.Telemetry, as: ThreatIntelTelemetry

  test "rejects non-IP input before querying" do
    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "not-an-ip")

    assert {:error, :invalid_ip} = ThreatIntelInvestigation.indicators_for_ip(:unused, "")

    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "010.0.0.1")

    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "10.0.0.0/8")

    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "1; DROP TABLE")

    assert {:error, :invalid_ip} = ThreatIntelInvestigation.indicators_for_ip(:unused, nil)
  end

  describe "flow_summary/3" do
    @summaries %{
      "192.0.2.10" => %{match_count: 2, max_severity: 3, sources: ["feed_a"]},
      "198.51.100.20" => %{match_count: 1, max_severity: 7, sources: ["feed_a", "feed_b"]}
    }

    test "folds both matched endpoints into one flow summary" do
      summary = ThreatIntelInvestigation.flow_summary(@summaries, "192.0.2.10", "198.51.100.20")

      assert summary.match_count == 3
      assert summary.max_severity == 7
      assert summary.sources == ["feed_a", "feed_b"]
      assert summary.source == @summaries["192.0.2.10"]
      assert summary.destination == @summaries["198.51.100.20"]
    end

    test "reports only the matched side and nil when neither side matches" do
      summary = ThreatIntelInvestigation.flow_summary(@summaries, "203.0.113.5", "198.51.100.20")

      assert summary.match_count == 1
      assert is_nil(summary.source)
      assert ThreatIntelInvestigation.flow_summary(@summaries, "203.0.113.5", nil) == nil
    end

    test "counts an endpoint once when it is both source and destination" do
      summary = ThreatIntelInvestigation.flow_summary(@summaries, "192.0.2.10", "192.0.2.10")

      assert summary.match_count == 2
      assert is_nil(summary.destination)
    end
  end

  test "endpoint lookup rejects an unbounded address list before querying" do
    ips = for n <- 0..500, do: "2001:db8::#{Integer.to_string(n, 16)}"

    assert {:error, {:too_many_endpoints, 501, 500}} =
             ThreatIntelInvestigation.endpoint_summaries(:unused, ips)

    assert {:ok, %{}} =
             ThreatIntelInvestigation.endpoint_summaries(:unused, [
               "",
               nil,
               "not-an-ip",
               "Unknown"
             ])
  end

  describe "keyset cursors" do
    alias ServiceRadar.Observability.ThreatIntelInvestigation.Keyset

    test "a page cursor decodes back to the last row's key" do
      at = ~U[2026-01-02 03:04:05.123456Z]

      rows = [
        %{at: ~U[2026-01-02 04:00:00Z], ip: "192.0.2.1"},
        %{at: at, ip: "192.0.2.2"},
        %{at: at, ip: "192.0.2.3"}
      ]

      assert %{rows: [_, _], next_cursor: cursor} = Keyset.page(rows, 2, &[&1.at, &1.ip])
      assert {:ok, [^at, "192.0.2.2"]} = Keyset.decode(cursor, [:datetime, :string])
      assert %{next_cursor: nil} = Keyset.page(rows, 3, &[&1.at, &1.ip])
    end

    test "a malformed or mismatched cursor is an explicit error" do
      cursor = Keyset.encode([5, "192.0.2.1"])

      assert {:ok, nil} = Keyset.decode("", [:integer, :string])
      assert {:error, :invalid_cursor} = Keyset.decode("%%%", [:integer, :string])
      assert {:error, :invalid_cursor} = Keyset.decode(cursor, [:datetime, :string])
      assert {:error, :invalid_cursor} = Keyset.decode(cursor, [:integer])

      assert {:error, :invalid_cursor} =
               Keyset.decode(Keyset.encode(["x", "not-a-uuid"]), [:string, :uuid])
    end
  end

  test "address filters keep IPv6 zero padding but reject a zero-padded IPv4 octet" do
    assert {:ok, "2001:0db8::1"} = ThreatIntelEvidence.parse_address("2001:0db8::1", :ip)
    assert {:ok, "10.0.0.1"} = ThreatIntelEvidence.parse_address("10.0.0.1", :ip)
    assert {:error, :invalid_ip} = ThreatIntelEvidence.parse_address("010.0.0.1", :ip)
    assert {:error, :invalid_ip} = ThreatIntelEvidence.parse_address("10.0.00.1", :ip)
  end

  test "formatted statement and queue timeouts classify as timeout and omit the error text" do
    secret = "provider-credential-synthetic"

    statement_timeout =
      "** (Postgrex.Error) ERROR 57014 (query_canceled) canceling statement due to statement timeout #{secret}"

    queue_timeout =
      "** (DBConnection.ConnectionError) connection not available and request was dropped from queue after 1000ms. #{secret}"

    reasons = [
      statement_timeout,
      %{errors: [%{error: statement_timeout}]},
      %{errors: [%{error: "relation missing #{secret}"}, %{error: queue_timeout}]},
      %{error: queue_timeout},
      %{postgres: %{code: :query_canceled}},
      %DBConnection.ConnectionError{reason: :queue_timeout},
      %DBConnection.ConnectionError{reason: :timeout}
    ]

    for reason <- reasons do
      metadata = span_stop({:error, reason}, ip: secret)

      assert %{entity: :current_matches, filters: [:ip], result: :error, error: :timeout} =
               metadata

      refute inspect(metadata) =~ secret
      refute inspect(metadata) =~ "query_canceled"
      refute inspect(metadata) =~ "queue_timeout"
    end

    refused = span_stop({:error, "password authentication failed for #{secret}"}, ip: secret)

    assert %{result: :error, error: :query_failed, filters: [:ip]} = refused
    refute inspect(refused) =~ secret

    invalid = span_stop({:error, :invalid_ip}, ip: secret)
    assert %{result: :error, error: :invalid_input, filters: [:ip]} = invalid
    refute inspect(invalid) =~ secret

    counted = span_stop({:ok, [1, 2]}, source: secret)
    assert %{entity: :current_matches, result: :ok, result_count: 2, filters: [:source]} = counted
    refute inspect(counted) =~ secret
  end

  test "indicator filters accept only addresses PostgreSQL takes as cidr" do
    for accepted <- [
          "198.51.100.0/24",
          "198.51.100.10/32",
          "198.51.100.10",
          "2001:db8::/32",
          "0.0.0.0/0"
        ] do
      assert {:ok, ^accepted} = ThreatIntelEvidence.parse_address(accepted, :cidr)
    end

    for rejected <- [
          "198.51.100.10/24",
          "198.51.100.1/31",
          "2001:db8::1/64",
          "198.51.100.0/33",
          "198.51.100.0/-10000000000",
          "192.168.001.000/24",
          "010.0.0.1",
          "not-an-ip"
        ] do
      assert {:error, :invalid_cidr} = ThreatIntelEvidence.parse_address(rejected, :cidr)
    end
  end

  defp span_stop(result, opts) do
    handler = "threat-intel-class-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      ThreatIntelTelemetry.event() ++ [:stop],
      fn _event, _measurements, metadata, _ ->
        if self() == test_pid, do: send(test_pid, {:investigation_stop, metadata})
      end,
      nil
    )

    try do
      assert result == ThreatIntelTelemetry.span(:current_matches, opts, fn -> result end)
      assert_receive {:investigation_stop, metadata}
      metadata
    after
      :telemetry.detach(handler)
    end
  end
end
