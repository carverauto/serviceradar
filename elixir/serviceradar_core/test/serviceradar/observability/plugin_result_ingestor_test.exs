defmodule ServiceRadar.Observability.PluginResultIngestorTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Repo

  defmodule FailingHandler do
    @moduledoc false

    def supports?(_payload, _status), do: true

    def ingest(payload, _status, _opts) do
      notify_test({:failing_handler_ingest, payload})
      {:error, :forced_failure}
    end

    defp notify_test(message) do
      if pid = Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule RaisingSupportHandler do
    @moduledoc false

    def supports?(_payload, _status) do
      raise "support check failed api_token: \"do-not-persist\""
    end

    def ingest(_payload, _status, _opts) do
      send(
        Application.fetch_env!(:serviceradar_core, :plugin_result_ingestor_test_pid),
        :unexpected_support_handler_ingest
      )

      :ok
    end
  end

  defmodule LongErrorHandler do
    @moduledoc false

    def supports?(_payload), do: true

    def ingest(_payload, _status, _opts) do
      {:error,
       %{
         api_token: "do-not-persist",
         detail: String.duplicate("x", 2_000)
       }}
    end
  end

  defmodule RejectingStateRegistry do
    @moduledoc false
    def upsert_from_status_strict(_status), do: {:error, :forced_state_failure}
  end

  setup do
    previous_handlers = Application.get_env(:serviceradar_core, :plugin_result_handlers)

    previous_registry =
      Application.get_env(:serviceradar_core, :plugin_result_state_registry)

    previous_test_pid =
      Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_pid)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [FailingHandler])
    Application.put_env(:serviceradar_core, :plugin_result_ingestor_test_pid, self())

    on_exit(fn ->
      restore_env(:plugin_result_handlers, previous_handlers)
      restore_env(:plugin_result_state_registry, previous_registry)
      restore_env(:plugin_result_ingestor_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "records downstream handler failures as the current unavailable state" do
    {payload, status, observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert_receive {:failing_handler_ingest, ^payload}

    assert [
             [^observed_at, true, "edge plugin completed", _reported_details],
             [failed_at, false, failure_message, details]
           ] = history_rows(status)

    assert failed_at == DateTime.add(observed_at, 1, :microsecond)

    assert failure_message ==
             "Plugin result downstream ingest failed: " <>
               "ServiceRadar.Observability.PluginResultIngestorTest.FailingHandler"

    assert %{
             "downstream_ingest" => %{
               "status" => "failed",
               "handlers" => [
                 %{
                   "handler" =>
                     "ServiceRadar.Observability.PluginResultIngestorTest.FailingHandler",
                   "error" => ":forced_failure"
                 }
               ]
             },
             "reported_result" => ^payload
           } = Jason.decode!(details)

    assert [[false, ^failure_message, ^failed_at]] = current_state_rows(status)
  end

  test "duplicate observations rerun handlers without duplicating history" do
    {payload, status, observed_at} = plugin_result_fixture()

    expected_error =
      {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}}

    assert ^expected_error = PluginResultIngestor.ingest(payload, status)
    assert ^expected_error = PluginResultIngestor.ingest(payload, status)

    assert_receive {:failing_handler_ingest, ^payload}
    assert_receive {:failing_handler_ingest, ^payload}

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [failed_at, false, _, _]
           ] = history_rows(status)

    assert failed_at == DateTime.add(observed_at, 1, :microsecond)
  end

  test "older observations cannot replace newer current state" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    newer_at = DateTime.add(observed_at, 10, :second)

    newer_payload = %{
      payload
      | "status" => "CRITICAL",
        "summary" => "newer critical result",
        "observed_at" => DateTime.to_iso8601(newer_at)
    }

    assert :ok = PluginResultIngestor.ingest(newer_payload, status)
    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert [[false, "newer critical result", ^newer_at]] = current_state_rows(status)
  end

  test "unavailable wins equal-timestamp current-state conflicts in either arrival order" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {healthy_payload, first_status, observed_at} = plugin_result_fixture()

    unavailable_payload = %{
      healthy_payload
      | "status" => "CRITICAL",
        "summary" => "same-time critical result"
    }

    assert :ok = PluginResultIngestor.ingest(healthy_payload, first_status)
    assert :ok = PluginResultIngestor.ingest(unavailable_payload, first_status)
    assert :ok = PluginResultIngestor.ingest(healthy_payload, first_status)

    assert [[false, "same-time critical result", ^observed_at]] =
             current_state_rows(first_status)

    {_payload, second_status, _observed_at} = plugin_result_fixture()

    assert :ok = PluginResultIngestor.ingest(unavailable_payload, second_status)
    assert :ok = PluginResultIngestor.ingest(healthy_payload, second_status)

    assert [[false, "same-time critical result", ^observed_at]] =
             current_state_rows(second_status)
  end

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
    refute error_text =~ "do-not-persist"

    assert [_, [_, false, _, details]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "handlers" => [%{"error" => persisted_error}]
             }
           } = Jason.decode!(details)

    assert persisted_error == error_text
  end

  test "does not discard failure-state persistence errors" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_state_registry,
      RejectingStateRegistry
    )

    {payload, status, _observed_at} = plugin_result_fixture()

    assert {:error,
            {:plugin_result_handler_failure_persistence_failed,
             [{FailingHandler, ":forced_failure"}], :forced_state_failure}} =
             PluginResultIngestor.ingest(payload, status)

    assert [_, [_, false, _, _]] = history_rows(status)
    assert [] = current_state_rows(status)
  end

  defp plugin_result_fixture do
    suffix = System.unique_integer([:positive])

    observed_at =
      DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:microsecond)

    payload = %{
      "status" => "OK",
      "summary" => "edge plugin completed",
      "observed_at" => DateTime.to_iso8601(observed_at)
    }

    status = %{
      source: "plugin-result",
      agent_id: "plugin-handler-agent-#{suffix}",
      gateway_id: "plugin-handler-gateway-#{suffix}",
      partition: "default",
      service_type: "plugin",
      service_name: "plugin-handler-service-#{suffix}"
    }

    {payload, status, observed_at}
  end

  defp history_rows(status) do
    Repo.query!(
      """
      SELECT timestamp, available, message, details
      FROM platform.service_status
      WHERE gateway_id = $1 AND service_name = $2
      ORDER BY timestamp
      """,
      [status.gateway_id, status.service_name]
    ).rows
  end

  defp current_state_rows(status) do
    Repo.query!(
      """
      SELECT available, message, last_observed_at AT TIME ZONE 'UTC'
      FROM platform.service_state
      WHERE agent_id = $1
        AND gateway_id = $2
        AND partition = 'default'
        AND service_type = 'plugin'
        AND service_name = $3
      """,
      [status.agent_id, status.gateway_id, status.service_name]
    ).rows
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
