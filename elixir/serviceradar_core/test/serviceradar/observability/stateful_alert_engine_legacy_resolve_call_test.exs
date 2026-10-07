defmodule ServiceRadar.Observability.StatefulAlertEngineLegacyResolveCallTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.StatefulAlertEngine

  setup do
    previous = Application.fetch_env(:serviceradar_core, :alert_evaluation_mode)
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :prepared)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:serviceradar_core, :alert_evaluation_mode, value)
        :error -> Application.delete_env(:serviceradar_core, :alert_evaluation_mode)
      end
    end)
  end

  test "both public maintenance arities reject an unactivated deployment" do
    now = ~U[2026-01-01 00:00:00Z]
    cutoff = DateTime.shift(now, hour: -1)

    assert {:error, :alert_evaluation_not_activated} =
             StatefulAlertEngine.resolve_stale_anomalies("synthetic-rule", cutoff, now)

    assert {:error, :alert_evaluation_not_activated} =
             StatefulAlertEngine.resolve_stale_anomalies(
               "synthetic-rule",
               cutoff,
               now,
               MapSet.new()
             )
  end
end
