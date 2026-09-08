defmodule ServiceRadar.EventWriter.Processors.TrivyReportsScanActivityTest do
  # Mutates application env (the scan-activity emission flag), so it cannot be async.
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Processors.TrivyReports

  @flag :trivy_scan_activity_events

  setup do
    original = Application.get_env(:serviceradar_core, @flag)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:serviceradar_core, @flag)
        value -> Application.put_env(:serviceradar_core, @flag, value)
      end
    end)

    :ok
  end

  describe "emit_scan_activity_events?/0 (default: suppressed)" do
    setup do
      Application.delete_env(:serviceradar_core, @flag)
      :ok
    end

    test "routine scan-completed status events are NOT emitted to ocsf_events by default" do
      refute TrivyReports.emit_scan_activity_events?()
    end
  end

  describe "emit_scan_activity_events?/0 with the flag enabled" do
    test "scan-completed status events are emitted when the flag is true" do
      Application.put_env(:serviceradar_core, @flag, true)
      assert TrivyReports.emit_scan_activity_events?()
    end

    test "non-true flag values leave scan-completed events suppressed" do
      Application.put_env(:serviceradar_core, @flag, "yes")
      refute TrivyReports.emit_scan_activity_events?()

      Application.put_env(:serviceradar_core, @flag, 1)
      refute TrivyReports.emit_scan_activity_events?()
    end
  end
end
