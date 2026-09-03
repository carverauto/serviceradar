defmodule ServiceRadar.ResultsRouterAdmissionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.ResultsRouter

  defmodule TestPluginIngestor do
    @moduledoc false

    def ingest(_payload, _status) do
      Application.fetch_env!(:serviceradar_core, :plugin_result_ingestor_test_result)
    end
  end

  setup do
    previous_ingestor = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
    previous_result = Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_result)

    Application.put_env(:serviceradar_core, :plugin_result_ingestor, TestPluginIngestor)

    on_exit(fn ->
      restore_env(:plugin_result_ingestor, previous_ingestor)
      restore_env(:plugin_result_ingestor_test_result, previous_result)
    end)
  end

  test "acknowledges a durably recorded handler-domain failure" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_ingestor_test_result,
      {:error, {:plugin_result_handlers_failed, [{TestPluginIngestor, "failed"}]}}
    )

    assert :ok = ResultsRouter.process_retained_plugin(status())
  end

  test "preserves retryable persistence failures" do
    error = {:error, {:plugin_result_status_persistence_failed, "database unavailable"}}
    Application.put_env(:serviceradar_core, :plugin_result_ingestor_test_result, error)

    assert ^error = ResultsRouter.process_retained_plugin(status())
  end

  defp status do
    %{
      source: "plugin-result",
      service_type: "plugin",
      message: Jason.encode!(%{"status" => "OK", "summary" => "plugin ok"}),
      agent_id: "agent-1"
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
