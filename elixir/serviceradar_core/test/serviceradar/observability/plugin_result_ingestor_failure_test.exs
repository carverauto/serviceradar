defmodule ServiceRadar.Observability.PluginResultIngestorFailureTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  test "support check exceptions become sanitized handler failures" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [RaisingSupportHandler]
    )

    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{RaisingSupportHandler, error_text}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert error_text =~ "support_check_failed"
    assert error_text =~ "[REDACTED]"
    refute error_text =~ "do-not-persist"
    refute_received :unexpected_support_handler_ingest

    assert [[false, _, _]] = current_state_rows(status)

    assert [_, [_, false, _, details]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "handlers" => [%{"error" => ^error_text}]
             }
           } = Jason.decode!(details)
  end

  test "handler errors are redacted and bounded before logging or persistence" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [LongErrorHandler])
    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{LongErrorHandler, error_text}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert byte_size(error_text) <= 1_000
    assert error_text =~ "[REDACTED]"

    for secret <- [
          "do-not-persist",
          "bearer-structured-secret",
          "credential-structured-secret",
          "private-key-structured-secret",
          "bare-token-structured-secret",
          "bearer-text-secret",
          "bare-token-text-secret",
          "credential-text-secret",
          "private-key-text-secret",
          "pem-text-secret"
        ] do
      refute error_text =~ secret
    end

    assert [_, [_, false, _, details]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "handlers" => [%{"error" => persisted_error}]
             }
           } = Jason.decode!(details)

    assert persisted_error == error_text
  end

  test "long PEM values and Basic authorization are redacted before truncation" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [SensitiveCredentialHandler]
    )

    {payload, status, _observed_at} = plugin_result_fixture()

    captured_log =
      capture_log(fn ->
        send(self(), {:sensitive_result, PluginResultIngestor.ingest(payload, status)})
      end)

    assert_receive {:sensitive_result,
                    {:error,
                     {:plugin_result_handlers_failed, [{SensitiveCredentialHandler, error_text}]}}}

    assert error_text =~ "[REDACTED]"
    assert error_text =~ "[REDACTED PRIVATE KEY]"

    assert [_, [_, false, _, details]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "handlers" => [%{"error" => persisted_error}]
             }
           } = Jason.decode!(details)

    assert persisted_error == error_text

    for secret <- [
          "basic-auth-secret",
          "long-pem-secret",
          "unterminated-pem-secret"
        ] do
      refute error_text =~ secret
      refute persisted_error =~ secret
      refute captured_log =~ secret
    end
  end

  test "textual bearer, token, credential, and private key forms are redacted" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [TextErrorHandler])
    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{TextErrorHandler, error_text}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert error_text =~ "[REDACTED]"

    for secret <- [
          "bearer-text-secret",
          "bare-token-text-secret",
          "credential-text-secret",
          "private-key-text-secret",
          "pem-text-secret"
        ] do
      refute error_text =~ secret
    end

    assert [_, [_, false, _, details]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "handlers" => [%{"error" => ^error_text}]
             }
           } = Jason.decode!(details)
  end

  test "handler throws and exits become redacted failures" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [ThrowingHandler, ExitingHandler]
    )

    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error,
            {:plugin_result_handlers_failed,
             [{ThrowingHandler, throw_error}, {ExitingHandler, exit_error}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert throw_error =~ "throw"
    assert throw_error =~ "[REDACTED]"
    refute throw_error =~ "throw-token-secret"

    assert exit_error =~ "exit"
    assert exit_error =~ "[REDACTED]"
    refute exit_error =~ "exit-credential-secret"
    assert [[false, _, _]] = current_state_rows(status)
  end

  test "top-level ingest exceptions return only bounded sanitized text" do
    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_ingest_failed, error_text}} =
             PluginResultIngestor.ingest(payload, {:invalid_status, status})

    assert is_binary(error_text)
    assert String.valid?(error_text)
    assert byte_size(error_text) <= 1_000
  end

  test "state persistence errors roll back markers and release the observation lock" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_state_registry,
      RejectingStateRegistry
    )

    {payload, status, observed_at} = plugin_result_fixture()

    assert {:error,
            {:plugin_result_handler_failure_persistence_failed,
             [{FailingHandler, ":forced_failure"}], persistence_error}} =
             PluginResultIngestor.ingest(payload, status)

    assert persistence_error =~ "[REDACTED]"
    assert byte_size(persistence_error) <= 1_000
    refute persistence_error =~ "state-credential-secret"
    refute persistence_error =~ "state-private-key-secret"
    refute persistence_error =~ "state-token-secret"

    assert [[reported_at, true, "edge plugin completed", _] = reported_row] =
             history_rows(status)

    assert reported_at == assert_reported_event_block(reported_row, observed_at)
    assert [] = current_state_rows(status)

    Application.put_env(
      :serviceradar_core,
      :plugin_result_state_registry,
      ServiceStateRegistry
    )

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    failed_at = marker_timestamp(reported_at, 1, "failed")

    assert [
             [^reported_at, true, "edge plugin completed", _],
             [^failed_at, false, _, _]
           ] = history_rows(status)

    assert [[false, _, ^failed_at]] = current_state_rows(status)
  end
end
