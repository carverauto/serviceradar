defmodule ServiceRadar.Observability.EventTitleTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.EventTitle

  @cef_message "CEF:0|Ubiquiti|UniFi Network|10.4.57|578|Network Updated|4|UNIFIcategory=Software Updates UNIFIhost=farm01 msg=UniFi Network has updated to 10.4.57"

  test "derives alert titles from triggering CEF messages when stored title is generic" do
    assert EventTitle.alert_title(%{
             "title" => "Event: logs.syslog.processed",
             "description" => @cef_message
           }) == "UniFi Network has updated to 10.4.57"
  end

  test "keeps explicit non-generic alert titles" do
    assert EventTitle.alert_title(%{"title" => "Camera relay saturation"}) ==
             "Camera relay saturation"
  end

  test "falls back to CEF event name when no msg extension exists" do
    assert EventTitle.event_title(%{
             message: "CEF:0|Vendor|Product|1.0|578|Network Updated|4|src=10.0.0.1",
             log_name: "logs.syslog.processed"
           }) == "Network Updated"
  end
end
