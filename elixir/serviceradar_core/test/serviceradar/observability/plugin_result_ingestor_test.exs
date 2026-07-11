defmodule ServiceRadar.Observability.PluginResultIngestorTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Repo

  defmodule FailingHandler do
    @moduledoc false
    def supports?(_payload, _status), do: true
    def ingest(_payload, _status, _opts), do: {:error, :forced_failure}
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :plugin_result_handlers)
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [FailingHandler])

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, :plugin_result_handlers)
      else
        Application.put_env(:serviceradar_core, :plugin_result_handlers, previous)
      end
    end)

    :ok
  end

  test "records downstream handler failures as the current unavailable state" do
    suffix = System.unique_integer([:positive])
    agent_id = "plugin-handler-agent-#{suffix}"
    gateway_id = "plugin-handler-gateway-#{suffix}"
    service_name = "plugin-handler-service-#{suffix}"

    observed_at =
      DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:microsecond)

    payload = %{
      "status" => "OK",
      "summary" => "edge plugin completed",
      "observed_at" => DateTime.to_iso8601(observed_at)
    }

    status = %{
      source: "plugin-result",
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: "default",
      service_type: "plugin",
      service_name: service_name,
      available: true
    }

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, :forced_failure}]}} =
             PluginResultIngestor.ingest(payload, status)

    status_rows =
      Repo.query!(
        """
        SELECT available, message, details
        FROM platform.service_status
        WHERE gateway_id = $1 AND service_name = $2
        ORDER BY timestamp
        """,
        [gateway_id, service_name]
      ).rows

    assert [[true, "edge plugin completed", _reported_details], [false, failure_message, details]] =
             status_rows

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

    assert [[false, ^failure_message]] =
             Repo.query!(
               """
               SELECT available, message
               FROM platform.service_state
               WHERE agent_id = $1
                 AND gateway_id = $2
                 AND partition = 'default'
                 AND service_type = 'plugin'
                 AND service_name = $3
               """,
               [agent_id, gateway_id, service_name]
             ).rows
  end
end
