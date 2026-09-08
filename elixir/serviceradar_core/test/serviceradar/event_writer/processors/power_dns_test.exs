defmodule ServiceRadar.EventWriter.Processors.PowerDNSTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.EventWriter.Processors.PowerDNS

  describe "table_name/0" do
    test "uses the shared OCSF events table" do
      assert PowerDNS.table_name() == "ocsf_events"
    end
  end

  describe "parse_message/1" do
    test "parses OCSF DNS Activity events" do
      payload = %{
        "id" => Ecto.UUID.generate(),
        "time" => "2026-06-08T12:00:00Z",
        "class_uid" => OCSF.class_dns_activity(),
        "category_uid" => OCSF.category_network_activity(),
        "type_uid" => 400_302,
        "activity_id" => 2,
        "severity_id" => 3,
        "message" => "RPZ matched blocked.example",
        "metadata" => %{"version" => "1.8.0"},
        "firewall_rule" => %{"name" => "hagezi-pro"}
      }

      row =
        PowerDNS.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{subject: "pdns.ocsf"}
        })

      assert is_binary(row.id)
      assert row.class_uid == OCSF.class_dns_activity()
      assert row.category_uid == OCSF.category_network_activity()
      assert row.type_uid == 400_302
      assert row.activity_id == 2
      assert row.message == "RPZ matched blocked.example"
      assert row.log_name == "pdns.ocsf"
      assert row.metadata["version"] == "1.8.0"
    end

    test "skips non-DNS OCSF events" do
      payload = %{
        "id" => Ecto.UUID.generate(),
        "time" => "2026-06-08T12:00:00Z",
        "class_uid" => OCSF.class_event_log_activity(),
        "category_uid" => OCSF.category_system_activity(),
        "type_uid" => 100_801,
        "activity_id" => OCSF.activity_log_create(),
        "severity_id" => 1
      }

      assert PowerDNS.parse_message(%{
               data: Jason.encode!(payload),
               metadata: %{subject: "pdns.ocsf"}
             }) == nil
    end
  end
end
