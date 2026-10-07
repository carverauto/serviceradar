defmodule ServiceRadar.Observability.StatefulAlertEngineRepoUnavailableTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.StatefulAlertEngine

  setup do
    previous =
      Map.new([:repo_enabled, :alert_evaluation_mode], fn key ->
        {key, Application.fetch_env(:serviceradar_core, key)}
      end)

    Application.put_env(:serviceradar_core, :repo_enabled, false)
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :active)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_core, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_core, key)
      end)
    end)
  end

  test "a repository-disabled node rejects nonempty input rather than acknowledging it" do
    assert {:error, :alert_evaluation_capability_unavailable} =
             StatefulAlertEngine.evaluate_events([
               %{
                 id: Ash.UUID.generate(),
                 time: ~U[2026-01-01 00:00:00Z],
                 log_name: "synthetic.ready"
               }
             ])

    assert {:error, :alert_evaluation_capability_unavailable} =
             StatefulAlertEngine.evaluate_metrics([
               %{
                 id: Ash.UUID.generate(),
                 time: ~U[2026-01-01 00:00:00Z],
                 metric_name: "synthetic.cpu",
                 value: 1
               }
             ])
  end
end
