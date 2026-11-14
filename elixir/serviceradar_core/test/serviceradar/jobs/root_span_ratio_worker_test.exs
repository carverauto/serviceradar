defmodule ServiceRadar.Jobs.RootSpanRatioWorkerTest do
  use ExUnit.Case, async: true

  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceRequest
  alias Opentelemetry.Proto.Trace.V1.ResourceSpans
  alias Opentelemetry.Proto.Trace.V1.ScopeSpans
  alias Opentelemetry.Proto.Trace.V1.Span
  alias ServiceRadar.EventWriter.Processors.OtelTraces
  alias ServiceRadar.Jobs.RootSpanRatioWorker

  @threshold 0.85
  @min_spans 1000

  describe "evaluate/4" do
    test "skips when total is below the floor" do
      assert RootSpanRatioWorker.evaluate(0, 0, @min_spans, @threshold) == :skip
      assert RootSpanRatioWorker.evaluate(999, 999, @min_spans, @threshold) == :skip
    end

    test "evaluates exactly at the floor" do
      assert {:ok, ratio} = RootSpanRatioWorker.evaluate(1000, 100, @min_spans, @threshold)
      assert_in_delta ratio, 0.1, 1.0e-9
    end

    test "healthy ratio below the threshold" do
      assert {:ok, ratio} = RootSpanRatioWorker.evaluate(10_000, 500, @min_spans, @threshold)
      assert_in_delta ratio, 0.05, 1.0e-9
    end

    test "ratio exactly at the threshold is not a breach (strictly greater)" do
      assert {:ok, ratio} = RootSpanRatioWorker.evaluate(10_000, 8_500, @min_spans, @threshold)
      assert_in_delta ratio, 0.85, 1.0e-9
    end

    test "ratio above the threshold breaches" do
      assert {:breach, ratio} =
               RootSpanRatioWorker.evaluate(10_000, 8_501, @min_spans, @threshold)

      assert_in_delta ratio, 0.8501, 1.0e-9
    end

    test "all-root pathology breaches" do
      assert {:breach, ratio} =
               RootSpanRatioWorker.evaluate(5_000, 5_000, @min_spans, @threshold)

      assert ratio == 1.0
    end

    test "zero roots is healthy" do
      assert {:ok, +0.0} = RootSpanRatioWorker.evaluate(5_000, 0, @min_spans, @threshold)
    end

    test "respects a custom floor and threshold" do
      assert RootSpanRatioWorker.evaluate(99, 99, 100, 0.5) == :skip
      assert {:breach, _} = RootSpanRatioWorker.evaluate(100, 51, 100, 0.5)
      assert {:ok, _} = RootSpanRatioWorker.evaluate(100, 50, 100, 0.5)
    end
  end

  test "the warehouse count covers the same window, bounded by a UTC literal" do
    sql = RootSpanRatioWorker.warehouse_counts_sql(~U[2026-01-15 10:15:30Z])

    assert sql =~ "COUNT(*) AS total_spans"
    assert sql =~ "SUM(CASE WHEN parent_span_id IS NULL THEN 1 ELSE 0 END) AS root_spans"
    assert sql =~ "otel_traces WHERE `timestamp` > '2026-01-15 10:00:30'"
    refute sql =~ "NOW()"
  end

  describe "count_spans/1 with synthetic OTLP protobuf and JSON spans" do
    test "excludes linked consumer root spans from broken-parent ratio while retaining unlinked consumer roots and children" do
      upstream_trace = Base.decode16!("0102030405060708090A0B0C0D0E0F10")
      upstream_span = Base.decode16!("1112131415161718")

      # 10 synthetic linked consumer root spans (kind = SPAN_KIND_CONSUMER, parent_span_id = <<>>, non-empty links)
      linked_consumer_roots =
        for idx <- 1..10 do
          %Span{
            trace_id: :binary.copy(<<idx>>, 16),
            span_id: :binary.copy(<<idx>>, 8),
            parent_span_id: <<>>,
            name: "event_writer.process_batch",
            kind: :SPAN_KIND_CONSUMER,
            start_time_unix_nano: 1_768_471_200_000_000_000,
            end_time_unix_nano: 1_768_471_200_050_000_000,
            links: [
              %Span.Link{
                trace_id: upstream_trace,
                span_id: upstream_span,
                trace_state: ""
              }
            ]
          }
        end

      # 1 server root span + 4 child spans (including 1 child consumer span carrying links)
      server_trace = Base.decode16!("AAAAAAAAAAAAAAAA0000000000000001")
      server_root_id = Base.decode16!("BBBBBBBB00000001")

      server_and_children = [
        %Span{
          trace_id: server_trace,
          span_id: server_root_id,
          parent_span_id: <<>>,
          name: "HTTP POST /v1/traces",
          kind: :SPAN_KIND_SERVER,
          start_time_unix_nano: 1_768_471_200_000_000_000,
          end_time_unix_nano: 1_768_471_200_100_000_000,
          links: []
        },
        %Span{
          trace_id: server_trace,
          span_id: Base.decode16!("BBBBBBBB00000002"),
          parent_span_id: server_root_id,
          name: "decode_batch",
          kind: :SPAN_KIND_INTERNAL,
          start_time_unix_nano: 1_768_471_200_010_000_000,
          end_time_unix_nano: 1_768_471_200_020_000_000,
          links: []
        },
        %Span{
          trace_id: server_trace,
          span_id: Base.decode16!("BBBBBBBB00000003"),
          parent_span_id: server_root_id,
          name: "persist_batch",
          kind: :SPAN_KIND_INTERNAL,
          start_time_unix_nano: 1_768_471_200_020_000_000,
          end_time_unix_nano: 1_768_471_200_060_000_000,
          links: []
        },
        %Span{
          trace_id: server_trace,
          span_id: Base.decode16!("BBBBBBBB00000004"),
          parent_span_id: server_root_id,
          name: "child_consumer_with_link",
          kind: :SPAN_KIND_CONSUMER,
          start_time_unix_nano: 1_768_471_200_060_000_000,
          end_time_unix_nano: 1_768_471_200_080_000_000,
          links: [%Span.Link{trace_id: upstream_trace, span_id: upstream_span}]
        },
        %Span{
          trace_id: server_trace,
          span_id: Base.decode16!("BBBBBBBB00000005"),
          parent_span_id: server_root_id,
          name: "ack_batch",
          kind: :SPAN_KIND_INTERNAL,
          start_time_unix_nano: 1_768_471_200_080_000_000,
          end_time_unix_nano: 1_768_471_200_090_000_000,
          links: []
        }
      ]

      # 1 unlinked consumer root span (broken parent linkage: no parent_span_id AND empty links)
      unlinked_consumer_root = %Span{
        trace_id: Base.decode16!("CCCCCCCC000000000000000000000001"),
        span_id: Base.decode16!("DDDDDDDD00000001"),
        parent_span_id: <<>>,
        name: "orphan_consumer",
        kind: :SPAN_KIND_CONSUMER,
        start_time_unix_nano: 1_768_471_200_000_000_000,
        end_time_unix_nano: 1_768_471_200_030_000_000,
        links: []
      }

      encoded =
        ExportTraceServiceRequest.encode(%ExportTraceServiceRequest{
          resource_spans: [
            %ResourceSpans{
              scope_spans: [
                %ScopeSpans{
                  spans: linked_consumer_roots ++ server_and_children ++ [unlinked_consumer_root]
                }
              ]
            }
          ]
        })

      rows = OtelTraces.parse_message(%{data: encoded, metadata: %{subject: "otel.traces"}})
      assert length(rows) == 16

      # Without excluding the 10 linked consumer roots, roots/total would be 12/16 = 0.75;
      # with exclusion, eligible spans are 5 (server + 4 children) + 1 (unlinked consumer root) = 6,
      # and roots are 2 (server root + unlinked consumer root).
      assert {6, 2} = RootSpanRatioWorker.count_spans(rows)
      assert {:ok, ratio} = RootSpanRatioWorker.evaluate(6, 2, 5, @threshold)
      assert_in_delta ratio, 2 / 6, 1.0e-9
    end

    test "excludes JSON-ingested linked consumer root spans while counting JSON unlinked consumer roots" do
      linked_json_consumer =
        OtelTraces.parse_message(%{
          data:
            Jason.encode!(%{
              "timestamp" => "2026-01-15T10:05:00Z",
              "trace_id" => "11111111111111111111111111111111",
              "span_id" => "2222222222222222",
              "parent_span_id" => nil,
              "name" => "nats.consume",
              "kind" => 5,
              "links" => [
                %{
                  "trace_id" => "33333333333333333333333333333333",
                  "span_id" => "4444444444444444"
                }
              ]
            }),
          metadata: %{}
        })

      unlinked_nil_consumer =
        OtelTraces.parse_message(%{
          data:
            Jason.encode!(%{
              "timestamp" => "2026-01-15T10:05:01Z",
              "trace_id" => "55555555555555555555555555555555",
              "span_id" => "6666666666666666",
              "parent_span_id" => nil,
              "name" => "orphan.consume",
              "kind" => 5,
              "links" => nil
            }),
          metadata: %{}
        })

      non_consumer_root_with_links =
        OtelTraces.parse_message(%{
          data:
            Jason.encode!(%{
              "timestamp" => "2026-01-15T10:05:02Z",
              "trace_id" => "77777777777777777777777777777777",
              "span_id" => "8888888888888888",
              "parent_span_id" => nil,
              "name" => "HTTP GET /status",
              "kind" => 2,
              "links" => [
                %{
                  "trace_id" => "33333333333333333333333333333333",
                  "span_id" => "4444444444444444"
                }
              ]
            }),
          metadata: %{}
        })

      assert {2, 2} =
               RootSpanRatioWorker.count_spans([
                 linked_json_consumer,
                 unlinked_nil_consumer,
                 non_consumer_root_with_links
               ])
    end
  end
end
