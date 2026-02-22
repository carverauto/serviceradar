defmodule ServiceRadar.Plugins.PluginInputPayloadBuilderTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.PluginInputPayloadBuilder
  alias ServiceRadar.Plugins.PluginInputs

  test "normalize_rows for devices maps expected fields and drops rows without uid" do
    rows = [
      %{
        uid: "sr:device:1",
        ip: "10.1.0.1",
        hostname: "axis-cam-1",
        vendor_name: "AXIS",
        tags: %{"brand" => "axis"}
      },
      %{
        "device_uid" => "sr:device:2",
        "device_ip" => "10.1.0.2",
        "name" => "axis-cam-2",
        "vendor" => "AXIS"
      },
      %{"ip" => "10.1.0.3"}
    ]

    assert [
             %{"uid" => "sr:device:1"} = first,
             %{"uid" => "sr:device:2"} = second
           ] = PluginInputPayloadBuilder.normalize_rows("devices", rows)

    assert first["vendor"] == "AXIS"
    assert first["labels"] == %{"brand" => "axis"}
    assert second["ip"] == "10.1.0.2"
    assert second["hostname"] == "axis-cam-2"
  end

  test "normalize_rows for interfaces maps interface identity and metadata" do
    rows = [
      %{
        interface_uid: "if:1",
        device_id: "sr:device:1",
        if_index: 10,
        if_name: "eth0",
        ip_addresses: ["192.168.10.2"]
      },
      %{
        "id" => "if:2",
        "device_uid" => "sr:device:2",
        "if_alias" => "uplink"
      },
      %{"if_name" => "missing-id"}
    ]

    assert [
             %{"id" => "if:1"} = first,
             %{"id" => "if:2"} = second
           ] = PluginInputPayloadBuilder.normalize_rows(:interfaces, rows)

    assert first["uid"] == "if:1"
    assert first["device_uid"] == "sr:device:1"
    assert first["if_index"] == 10
    assert first["ip_addresses"] == ["192.168.10.2"]
    assert second["if_alias"] == "uplink"
  end

  test "build_payloads chunks per input and validates generated payloads" do
    base = %{
      "policy_id" => "policy-1",
      "policy_version" => 1,
      "agent_id" => "agent-1",
      "generated_at" => "2026-02-21T22:00:00Z"
    }

    resolved_inputs = [
      %{
        name: "devices",
        entity: "devices",
        query: "in:devices vendor:AXIS",
        rows: [
          %{uid: "sr:device:1", ip: "10.0.0.1"},
          %{uid: "sr:device:2", ip: "10.0.0.2"},
          %{uid: "sr:device:3", ip: "10.0.0.3"}
        ]
      },
      %{
        "name" => "interfaces",
        "entity" => "interfaces",
        "query" => "in:interfaces if_name:eth*",
        "rows" => [
          %{"interface_uid" => "if:1", "device_id" => "sr:device:1"},
          %{"interface_uid" => "if:2", "device_id" => "sr:device:1"}
        ]
      }
    ]

    assert {:ok, payloads} =
             PluginInputPayloadBuilder.build_payloads(base, resolved_inputs, chunk_size: 2)

    assert length(payloads) == 3
    assert Enum.all?(payloads, &(:ok == PluginInputs.validate(&1)))
    assert Enum.all?(payloads, &(Map.get(&1, "schema") == PluginInputs.schema_id()))
    assert Enum.all?(payloads, &(length(&1["inputs"]) == 1))
  end

  test "build_payloads returns validation errors for missing descriptor fields" do
    base = %{
      "policy_id" => "policy-1",
      "policy_version" => 1,
      "agent_id" => "agent-1",
      "generated_at" => "2026-02-21T22:00:00Z"
    }

    invalid = [%{"entity" => "devices", "query" => "in:devices", "rows" => [%{"uid" => "x"}]}]

    assert {:error, errors} = PluginInputPayloadBuilder.build_payloads(base, invalid)
    assert Enum.any?(errors, &String.contains?(&1, "missing name"))
  end
end
