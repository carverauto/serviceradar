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

  test "replaces canned anomaly titles with metric and identity from the series key" do
    series_key =
      series_key(
        partition: "default",
        identity: "host01.example.com",
        metric: "ifHCInOctets",
        if_index: "4"
      )

    assert EventTitle.alert_title(%{
             "title" => "Anomaly Finding",
             "description" => "Causal prediction finding detected",
             "metadata" => %{
               "incident_rule_name" => "causal_prediction_health_finding",
               "incident_group_values" => %{
                 "device" => "sr:00000000-0000-4000-8000-000000000001",
                 "anomaly.series_key" => series_key
               }
             }
           }) == "Anomaly · ifHCInOctets · host01.example.com"
  end

  test "replaces canned Falco titles with the rule and host" do
    assert EventTitle.alert_title(%{
             "title" => "Falco Security Incident",
             "description" => "Falco security incident detected",
             "metadata" => %{
               "incident_group_values" => %{
                 "rule" => "Write below binary dir",
                 "hostname" => "host01.example.com"
               }
             }
           }) == "Write below binary dir · host01.example.com"
  end

  test "does not use a device uid as the only subject" do
    assert EventTitle.alert_title(%{
             "title" => "Anomaly Finding",
             "description" => "Causal prediction finding detected",
             "metadata" => %{
               "incident_group_values" => %{
                 "device" => "sr:00000000-0000-4000-8000-000000000001"
               }
             }
           }) == "Anomaly Finding"
  end

  defp series_key(components) do
    encoded =
      Enum.map_join(components, "|", fn {key, value} ->
        "#{key}=#{Base.encode16(to_string(value), case: :lower)}"
      end)

    "v2|" <> encoded
  end
end
