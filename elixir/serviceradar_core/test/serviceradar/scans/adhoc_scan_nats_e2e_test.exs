defmodule ServiceRadar.Scans.AdhocScanNatsE2ETest do
  @moduledoc """
  End-to-end ingestion test over a real NATS JetStream broker.

  Publishes an ad-hoc scan result to the `scans.results.>` stream on the
  configured NATS server (sr-testing), reads it back off the stream, and runs
  it through the `AdhocScan` event-writer processor into a real CNPG database —
  exercising the full durable-results path (publish -> JetStream -> processor ->
  `adhoc_scan_results`) rather than any single unit.

  Requires NATS + DB and is excluded by default (`:external`). To run:

      NATS_TEST_HOST=192.168.10.31 NATS_TEST_PORT=31819 \\
      NATS_TEST_CERT_DIR=/path/to/mtls/certs \\
      SERVICERADAR_TEST_DATABASE_URL=... \\
      mix test --include external --include integration --no-start \\
        test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs
  """
  use ServiceRadar.DataCase, async: false

  alias Gnat.Jetstream.API.Stream, as: JsStream
  alias Gnat.Jetstream.API.Util
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.Processors.AdhocScan
  alias ServiceRadar.Scans.ScanResult

  @moduletag :integration
  @moduletag :external

  @stream "scan_results"
  @subject_prefix "scans.results"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "publish to JetStream then persist through the processor" do
    host = require_env("NATS_TEST_HOST")
    port = String.to_integer(System.get_env("NATS_TEST_PORT") || "4222")
    cert_dir = require_env("NATS_TEST_CERT_DIR")

    {:ok, conn} =
      Gnat.start_link(%{
        host: host,
        port: port,
        tls: true,
        ssl_opts: [
          certfile: String.to_charlist(Path.join(cert_dir, "client.crt")),
          keyfile: String.to_charlist(Path.join(cert_dir, "client.key")),
          cacertfile: String.to_charlist(Path.join(cert_dir, "ca.crt")),
          verify: :verify_none
        ]
      })

    ensure_stream(conn)

    scan_run_id = Ecto.UUID.generate()
    subject = "#{@subject_prefix}.#{scan_run_id}"

    row = %{
      "scan_run_id" => scan_run_id,
      "agent_id" => "e2e-agent",
      "target_ip" => "10.9.9.9",
      "mode" => "icmp",
      "available" => true,
      "response_ms" => 2.0,
      "timestamp_ms" => System.system_time(:millisecond)
    }

    :ok = Gnat.pub(conn, subject, Jason.encode!(row))

    message = fetch_message(conn, subject)
    assert message.data =~ scan_run_id

    assert {:ok, 1} = AdhocScan.process_batch([%{data: message.data, metadata: %{}}])

    {:ok, rows} = ScanResult.by_scan_run(scan_run_id, actor: SystemActor.system(:adhoc_scan_e2e))
    assert length(rows) == 1
    persisted = hd(rows)
    assert persisted.target_ip == "10.9.9.9"
    assert persisted.mode == "icmp"
    assert persisted.available == true

    Gnat.stop(conn)
  end

  defp ensure_stream(conn) do
    payload =
      Jason.encode!(%{
        name: @stream,
        subjects: ["#{@subject_prefix}.>"],
        retention: "limits",
        storage: "file",
        discard: "old",
        num_replicas: 1
      })

    # Idempotent: ignore "stream already exists" and config-overlap responses.
    Util.request(conn, "$JS.API.STREAM.CREATE.#{@stream}", payload)
    :ok
  end

  defp fetch_message(conn, subject, attempts \\ 20)

  defp fetch_message(_conn, subject, 0), do: flunk("message never appeared on #{subject}")

  defp fetch_message(conn, subject, attempts) do
    case JsStream.get_message(conn, @stream, %{last_by_subj: subject}) do
      {:ok, message} ->
        message

      _ ->
        Process.sleep(200)
        fetch_message(conn, subject, attempts - 1)
    end
  end

  defp require_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> flunk("#{name} must be set to run this external NATS test")
    end
  end
end
