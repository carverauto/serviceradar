defmodule ServiceRadarWebNGWeb.EventLive.AnomalySummaryTimezoneTest do
  @moduledoc """
  The anomaly finding summary is a function component. It only receives the
  assigns listed in its `attr` declarations, so reading `@current_scope` there
  crashes the LiveView as soon as metric panels load.
  """

  use ExUnit.Case, async: true

  @moduletag :db_free

  @show_ex Path.expand("../../../../lib/serviceradar_web_ng_web/live/event_live/show.ex", __DIR__)

  test "anomaly_detection_summary takes timezone explicitly and does not read current_scope" do
    source = File.read!(@show_ex)

    assert source =~
             ~r/attr\(:metrics_error, :any, default: nil\)\n\s+attr\(:timezone, :string, required: true\)\n\n\s+defp anomaly_detection_summary/

    [callsite] = Regex.run(~r/<\.anomaly_detection_summary\b.*?\/>/s, source)
    assert callsite =~ "timezone={@current_scope.user.timezone}"

    refute source =~
             "panel_assigns={anomaly_panel_assigns(panel, @chart_focus, @current_scope.user.timezone)}"

    assert source =~ "panel_assigns={anomaly_panel_assigns(panel, @chart_focus, @timezone)}"
  end
end
