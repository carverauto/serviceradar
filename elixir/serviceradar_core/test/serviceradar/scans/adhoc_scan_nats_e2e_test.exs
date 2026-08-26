defmodule ServiceRadar.Scans.AdhocScanNatsE2ETest do
  @moduledoc """
  End-to-end ingestion test over a real NATS JetStream broker.

  Publishes an ad-hoc scan result to the `scans.results.>` stream on the
  configured NATS server (sr-testing), reads it back off the stream, and runs
  it through the `AdhocScan` event-writer processor into a real CNPG database —
  exercising the full durable-results path (publish -> JetStream -> processor ->
  `adhoc_scan_results`) rather than any single unit.

  Requires NATS + DB. The broker is the `sr-testing-nats` fixture in the
  `sr-testing` namespace (NodePort 31819, mTLS via the `sr-testing-nats-tls`
  secret, whose `ca.crt`/`client.crt`/`client.key` are exactly the three files
  NATS_TEST_CERT_DIR must contain).

  NOTE on tags: `:external` alone does NOT keep this out of a run. An ExUnit
  `--include` filter OVERRIDES `--exclude`, so a manual
  `mix test --include integration` matches the `:integration` tag and pulls this
  test in regardless of `:external`. The env guard below is what
  actually keeps it from failing when the fixture is not wired up -- it SKIPS
  rather than flunks, so an unconfigured runner is green instead of red.

  To run:

      NATS_TEST_HOST=192.168.10.31 NATS_TEST_PORT=31819 \\
      NATS_TEST_CERT_DIR=/path/to/mtls/certs \\
      SERVICERADAR_TEST_DATABASE_URL=<srql-fixtures-codex-scratch-url> \\
      SRQL_TEST_DATABASE_SERVER_NAME=srql-fixture-rw.srql-fixtures.svc.cluster.local \\
      SRQL_TEST_DATABASE_CA_CERT_FILE=/path/to/srql-fixture-ca.crt \\
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

  # Without the fixture wired up this test used to FLUNK on every CI run
  # (NATS_TEST_HOST is not set), which is why `CI / build` was red on staging
  # and on every pull request. Skip instead: configured -> exercised, not
  # configured -> skipped, never a false red.
  # Three distinct states, so a lost secret can never masquerade as "no fixture":
  #   none configured        -> SKIP (untrusted fork / local dev, no secrets at all)
  #   PARTIALLY configured   -> FAIL, naming the missing variables
  #   fully configured       -> RUN
  @nats_vars ["NATS_TEST_HOST", "NATS_TEST_CERT_DIR"]
  @nats_present Enum.filter(@nats_vars, &(System.get_env(&1) not in [nil, ""]))
  @nats_missing @nats_vars -- @nats_present
  @nats_configured @nats_missing == []
  @nats_partial @nats_present != [] and @nats_missing != []

  # A partial configuration must FAIL rather than skip, so renaming or deleting
  # one secret on a trusted runner is loud instead of silently disabling this
  # test. Only a completely unconfigured environment skips.
  @moduletag skip: not @nats_configured and not @nats_partial

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

    # The server name is what makes the supplied CA meaningful. Under
    # `verify: :verify_none` the `cacertfile` authenticates nothing, so this test
    # would pass against ANY TLS-speaking endpoint at the configured address
    # without ever proving it reached the sr-testing fixture. Default matches
    # k8s/sr-testing/export-nats-env.sh (NATS_SERVER_NAME=sr-testing-nats).
    server_name = System.get_env("NATS_TEST_SERVER_NAME") || "sr-testing-nats"

    {:ok, conn} =
      Gnat.start_link(%{
        host: host,
        port: port,
        tls: true,
        ssl_opts: [
          certfile: String.to_charlist(Path.join(cert_dir, "client.crt")),
          keyfile: String.to_charlist(Path.join(cert_dir, "client.key")),
          cacertfile: String.to_charlist(Path.join(cert_dir, "ca.crt")),
          verify: :verify_peer,
          server_name_indication: String.to_charlist(server_name),
          depth: 2
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
