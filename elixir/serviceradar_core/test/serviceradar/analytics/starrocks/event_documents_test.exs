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

  test "an OTel metric listing comes back with the booleans CNPG returns" do
    slow = %{"timestamp" => "2026-01-15T10:00:00Z", "span_name" => "GET /cart", "is_slow" => 1}
    fast = %{"timestamp" => "2026-01-15T10:00:01Z", "span_name" => "GET /cart", "is_slow" => 0}

    unknown = %{
      "timestamp" => "2026-01-15T10:00:02Z",
      "span_name" => "GET /cart",
      "is_slow" => nil
    }

    for entity <- ~w(otel_metrics metrics) do
      assert [%{"is_slow" => true}, %{"is_slow" => false}, %{"is_slow" => nil}] =
               EventDocuments.decode_rows([slow, fast, unknown], entity)
    end

    point = %{
      "timestamp" => "2026-01-15T10:00:00Z",
      "metric_name" => "requests",
      "is_monotonic" => 1
    }

    for entity <- ~w(otel_metric_points metric_points) do
      assert [%{"is_monotonic" => true, "metric_name" => "requests"}] =
               EventDocuments.decode_rows([point], entity)
    end
  end

  test "an OTel metric count is returned unchanged, even under a flag's name" do
    rows = [%{"service_name" => "checkout", "is_slow" => 1}]
    assert EventDocuments.decode_rows(rows, "otel_metrics") == rows
  end

  test "a trace summary listing comes back with the service set CNPG returns" do
    summary = %{"trace_id" => "trace-alpha-0001", "service_set" => ~s(["svc-a","svc-b"])}
    empty = %{"trace_id" => "trace-alpha-0002", "service_set" => nil}

    for entity <- ~w(otel_trace_summaries trace_summaries) do
      assert [%{"service_set" => ["svc-a", "svc-b"]}, %{"service_set" => nil}] =
               EventDocuments.decode_rows([summary, empty], entity)
    end
  end

  test "a trace summary count is returned unchanged, even under the set's name" do
    rows = [%{"service_set" => 3}]
    assert EventDocuments.decode_rows(rows, "otel_trace_summaries") == rows
  end

  test "a BMP row listing comes back with its metadata document decoded" do
    text = ~s({"signal_type":"bmp","event_type":"route_update"})
    row = %{"id" => "row-alpha-0001", "time" => "2026-01-15T10:00:00Z", "metadata" => text}

    for entity <- ~w(bmp_events bmp_event bmp_routing_events) do
      assert [%{"metadata" => %{"signal_type" => "bmp", "event_type" => "route_update"}}] =
               EventDocuments.decode_rows([row], entity)
    end

    # A listing row without an id still decodes: BMP has no stats path.
    assert [%{"metadata" => %{"signal_type" => "bmp"}}] =
             EventDocuments.decode_rows([%{"metadata" => ~s({"signal_type":"bmp"})}], "bmp_events")
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
