defmodule ServiceRadar.EventWriter.Processors.EventsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Cluster.TenantGuard
  alias ServiceRadar.EventWriter.Processors.Events

  describe "table_name/0" do
    test "returns correct table name" do
      assert Events.table_name() == "ocsf_events"
    end
  end

  describe "parse_message/1" do
    test "parses GELF syslog payload into OCSF event log activity" do
      payload = %{
        "short_message" => "disk nearly full",
        "level" => 4,
        "severity" => "warning",
        "host" => "web-01",
        "_remote_addr" => "192.0.2.10",
        "timestamp" => 1_705_315_800.123
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "events.syslog"}}

      row =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Events.parse_message(message)
        end)

      assert row.class_uid == 1008
      assert row.category_uid == 1
      assert row.activity_id == 1
      assert row.type_uid == 100_801
      assert row.message == "disk nearly full"
      assert row.severity_id == 3
      assert row.severity == "Medium"
      assert row.log_level == "warning"
      assert row.log_name == "events.syslog"
      assert row.log_provider == "web-01"
      assert row.tenant_id == "11111111-1111-1111-1111-111111111111"
      assert %DateTime{} = row.time

      assert Enum.any?(row.observables, &(&1.name == "web-01"))
      assert Enum.any?(row.observables, &(&1.name == "192.0.2.10"))
    end

    test "parses CloudEvents-wrapped syslog payloads" do
      event =
        %{
          "specversion" => "1.0",
          "subject" => "events.syslog",
          "source" => "syslog",
          "type" => "com.example.syslog",
          "time" => "2024-01-01T00:00:00Z",
          "data" => %{
            "short_message" => "login failed",
            "level" => 3
          }
        }

      row =
        with_tenant("22222222-2222-2222-2222-222222222222", fn ->
          Events.parse_message(%{data: Jason.encode!(event), metadata: %{}})
        end)

      assert row.log_name == "events.syslog"
      assert row.actor[:app_name] == "syslog"
      assert row.metadata[:correlation_uid] == "events.syslog"
      assert row.tenant_id == "22222222-2222-2222-2222-222222222222"
      assert row.message == "login failed"
      assert row.severity_id == 4
    end

    test "parses SNMP trap payloads into OCSF event log activity" do
      payload = %{
        "message" => "SNMP trap received",
        "severity" => "info",
        "varbinds" => [%{"oid" => "1.3.6.1.2.1.1.3.0", "value" => "123"}]
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "snmp.traps"}}

      row =
        with_tenant("33333333-3333-3333-3333-333333333333", fn ->
          Events.parse_message(message)
        end)

      assert row.message == "SNMP trap received"
      assert row.severity_id == 1
      assert row.log_name == "snmp.traps"
      assert row.tenant_id == "33333333-3333-3333-3333-333333333333"
    end
  end

  defp with_tenant(tenant_id, fun) when is_function(fun, 0) do
    previous = TenantGuard.get_process_tenant()
    TenantGuard.set_process_tenant(tenant_id)

    try do
      fun.()
    after
      restore_tenant(previous)
    end
  end

  defp restore_tenant(nil), do: Process.delete(:serviceradar_tenant)
  defp restore_tenant(tenant_id), do: TenantGuard.set_process_tenant(tenant_id)
end
