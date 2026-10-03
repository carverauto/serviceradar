defmodule ServiceRadar.NATS.BrokerErrorLogFilterTest do
  # Primary logger filters are node-global, so this cannot run async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.NATS.BrokerErrorLogFilter

  setup do
    :ok =
      BrokerErrorLogFilter.install(
        connection: :serviceradar_nats,
        endpoint: "nats.example.internal:4222",
        credentials: "tls_cert=/etc/serviceradar/certs/web.pem"
      )

    on_exit(fn -> :logger.remove_primary_filter(:serviceradar_nats_broker_errors) end)
  end

  test "logs the full broker error with the connection identity" do
    # A broker message longer than the inspect limit exporters apply, so a
    # truncating renderer would cut the subject off.
    subject = "logs.internal.audit." <> String.duplicate("x", 120)
    message = ~s(Permissions Violation for Publish to "#{subject}")

    # Exactly how Gnat reports a broker -ERR (Gnat.process_message/2).
    log = capture_log(fn -> :error_logger.error_report(type: :gnat_error_from_broker, message: message) end)

    assert log =~
             "NATS broker error on connection serviceradar_nats " <>
               "(nats.example.internal:4222, credentials: tls_cert=/etc/serviceradar/certs/web.pem): " <>
               message
  end

  test "leaves other error reports untouched" do
    log = capture_log(fn -> :error_logger.error_report(type: :some_other_report, message: "unrelated") end)

    assert log =~ "some_other_report"
    refute log =~ "NATS broker error"
  end
end
