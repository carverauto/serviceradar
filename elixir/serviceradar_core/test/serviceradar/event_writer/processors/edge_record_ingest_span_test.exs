defmodule ServiceRadar.EventWriter.Processors.EdgeRecordIngestSpanTest do
  # async: false — OtelSpanCapture restarts the global OpenTelemetry SDK.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.Otel
  alias ServiceRadar.TestSupport.OtelSpanCapture

  require Record

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @span_fields)

  @status_fields Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  Record.defrecordp(:status, @status_fields)

  setup do
    OtelSpanCapture.start!()
  end

  # Bytes that are no edge record and carry no publication headers: ingest refuses the record
  # before its transaction opens, so the span's lifecycle is observable without a database.
  defp undecodable_record do
    %{data: <<0, 1, 2>>, metadata: %{subject: "telemetry.edge-record.v1.bulk.p00", headers: %{}}}
  end

  test "a record's ingest is a CLIENT child of the batch span and records a failure as ERROR" do
    capture_log(fn ->
      Otel.span("event_writer.process_batch", %{kind: :consumer}, fn ->
        EdgeRecord.process_batch([undecodable_record()])
      end)
    end)

    assert_receive {:span, span(name: "edge_record.ingest", kind: :client) = ingest}, 1_000
    assert_receive {:span, span(name: "event_writer.process_batch") = batch}, 1_000

    assert span(ingest, :parent_span_id) == span(batch, :span_id)
    assert status(span(ingest, :status), :code) == :error

    attributes = :otel_attributes.map(span(ingest, :attributes))
    assert attributes["db.system"] == "postgresql"
    assert attributes["serviceradar.edge_record.outcome"] == "error"
  end

  test "a record ingested with no span active creates none" do
    capture_log(fn -> EdgeRecord.process_batch([undecodable_record()]) end)

    refute_receive {:span, _span}, 200
  end
end
