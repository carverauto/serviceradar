defmodule ServiceRadar.Observability.TripwireHealthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.TripwireHealth

  test "a failing health write logs and returns :ok (never crashes the tripwire)" do
    previous = Application.get_env(:serviceradar_core, :repo_enabled)
    Application.put_env(:serviceradar_core, :repo_enabled, false)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:serviceradar_core, :repo_enabled)
        value -> Application.put_env(:serviceradar_core, :repo_enabled, value)
      end
    end)

    log =
      capture_log(fn ->
        assert :ok = TripwireHealth.record("anomaly-alert-liveness", false, %{"reason" => "x"})
      end)

    assert log =~ "Failed to record tripwire health event"
  end
end
