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
    test "parses OCSF event payloads" do
      payload = %{
        "id" => "event-123",
        "time" => "2024-01-01T00:00:00Z",
        "class_uid" => 1008,
        "category_uid" => 1,
        "type_uid" => 100_801,
        "activity_id" => 1,
        "severity_id" => 5,
        "message" => "gateway offline",
        "metadata" => %{"version" => "1.7.0"}
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}

      row =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Events.parse_message(message)
        end)

      assert row.id == "event-123"
      assert row.class_uid == 1008
      assert row.category_uid == 1
      assert row.activity_id == 1
      assert row.type_uid == 100_801
      assert row.message == "gateway offline"
      assert row.severity_id == 5
      assert row.severity == "Critical"
      assert row.log_name == "events.ocsf.processed"
      assert row.tenant_id == "11111111-1111-1111-1111-111111111111"
      assert row.metadata["version"] == "1.7.0"
      assert %DateTime{} = row.time
      assert is_binary(row.raw_data)
    end

    test "returns nil when required fields are missing" do
      payload = %{
        "time" => "2024-01-01T00:00:00Z",
        "class_uid" => 1008
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}

      row =
        with_tenant("22222222-2222-2222-2222-222222222222", fn ->
          Events.parse_message(message)
        end)

      assert row == nil
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
