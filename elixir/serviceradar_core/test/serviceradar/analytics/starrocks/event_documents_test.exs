defmodule ServiceRadar.Analytics.StarRocks.EventDocumentsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Analytics.StarRocks.EventDocuments

  require Logger

  @moduletag :db_free

  test "an event row's documents come back as the maps and lists CNPG returns" do
    row = %{
      "id" => "evt-alpha-0001",
      "message" => ~s({"not":"a document column"}),
      "metadata" => ~s({"security_signal":{"finding_uid":"finding-0001"}}),
      "unmapped" => ~s({"log_attributes":{"rule":"synthetic rule"}}),
      "device" => ~s({"uid":"sr:device-0001","hostname":"host01.example.com"}),
      "observables" => ~s([{"name":"hostname","value":"host01.example.com"}])
    }

    for entity <- ~w(events security_findings scan_activity dns_activity) do
      assert [decoded] = EventDocuments.decode_rows([row], entity)

      assert decoded["metadata"] == %{"security_signal" => %{"finding_uid" => "finding-0001"}}
      assert decoded["unmapped"] == %{"log_attributes" => %{"rule" => "synthetic rule"}}
      assert decoded["device"] == %{"uid" => "sr:device-0001", "hostname" => "host01.example.com"}
      assert decoded["observables"] == [%{"name" => "hostname", "value" => "host01.example.com"}]

      # No other column is a document, whatever its text looks like.
      assert decoded["message"] == row["message"]
      assert decoded["id"] == "evt-alpha-0001"
    end
  end

  test "an empty document is an empty map and a NULL one stays nil" do
    row = %{"metadata" => "{}", "unmapped" => nil, "observables" => "[]"}

    assert [%{"metadata" => %{}, "unmapped" => nil, "observables" => []} = decoded] =
             EventDocuments.decode_rows([row], "events")

    # A column the result does not carry is not invented.
    refute Map.has_key?(decoded, "device")
  end

  test "text that does not decode is kept as it was, and says which column" do
    row = %{"metadata" => "not json", "unmapped" => ~s("a bare string"), "device" => "{}"}

    # The suite runs at :warning; only this process is turned up.
    Logger.put_process_level(self(), :debug)

    {decoded, log} =
      with_log([level: :debug], fn -> EventDocuments.decode_rows([row], "events") end)

    assert [%{"metadata" => "not json", "unmapped" => ~s("a bare string"), "device" => %{}}] =
             decoded

    assert log =~ "not a JSON object or array"
  end

  test "a stats result with none of the document columns is returned unchanged" do
    rows = [%{"total" => 12, "anomalies" => 3}]
    assert EventDocuments.decode_rows(rows, "events") == rows
  end

  test "an MTR row listing comes back with the list, document and boolean CNPG returns" do
    hop = %{
      "id" => "hop-alpha-0001",
      "addr" => "192.0.2.1",
      "ecmp_addrs" => ~s(["192.0.2.1","198.51.100.1"]),
      "mpls_labels" => ~s([{"label":16001,"exp":0,"s":1,"ttl":64}])
    }

    for entity <- ~w(mtr_hops mtr_hop_stats) do
      assert [decoded] = EventDocuments.decode_rows([hop], entity)
      assert decoded["ecmp_addrs"] == ["192.0.2.1", "198.51.100.1"]
      assert decoded["mpls_labels"] == [%{"label" => 16_001, "exp" => 0, "s" => 1, "ttl" => 64}]
      assert decoded["addr"] == "192.0.2.1"
    end

    reached = %{"id" => "trace-alpha-0001", "target_reached" => 1, "total_hops" => 1}
    missed = %{"id" => "trace-alpha-0002", "target_reached" => 0, "total_hops" => 0}

    assert [%{"target_reached" => true, "total_hops" => 1}, %{"target_reached" => false}] =
             EventDocuments.decode_rows([reached, missed], "mtr_traces")
  end

  test "an MTR stats row is returned unchanged, even under a row column's name" do
    rows = [%{"target_ip" => "192.0.2.10", "target_reached" => 1, "ecmp_addrs" => "[]"}]
    assert EventDocuments.decode_rows(rows, "mtr_traces") == rows
  end

  test "another dataset's rows are untouched, even with a column of the same name" do
    text = ~s({"site":"SITE01"})

    for entity <- ~w(logs flows timeseries_metrics devices) do
      rows = [%{"id" => "row-alpha-0001", "metadata" => text}]
      assert EventDocuments.decode_rows(rows, entity) == rows
    end

    assert EventDocuments.decode_rows([%{"metadata" => text}], nil) == [%{"metadata" => text}]
  end
end
