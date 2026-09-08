defmodule ServiceRadarWebNG.Devices.ManualDeviceCreatorAttrsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Devices.ManualDeviceCreator

  @moduletag :db_free

  test "additional_update_attrs merges tags and keeps a richer existing type" do
    existing = %{
      hostname: "armis-host",
      ip: "10.102.61.31",
      type: "server",
      type_id: 1,
      tags: %{"env" => "prod"},
      discovery_sources: ["armis"]
    }

    update =
      ManualDeviceCreator.additional_update_attrs(existing, %{
        hostname: "rids-bos-b23",
        ip: "10.102.61.31",
        type: "rids",
        type_id: 0,
        tags: %{"rids" => "true", "site" => "BOS"},
        discovery_sources: ["manual"],
        last_seen_time: ~U[2026-01-01 00:00:00Z]
      })

    assert update.hostname == "rids-bos-b23"
    assert update.name == "rids-bos-b23"
    refute Map.has_key?(update, :ip)
    refute Map.has_key?(update, :type)
    refute Map.has_key?(update, :type_id)
    assert update.tags == %{"env" => "prod", "rids" => "true", "site" => "BOS"}
    assert update.discovery_sources == ["armis", "manual"]
    assert update.is_active == true
  end

  test "additional_update_attrs fills a blank IP and an unknown type when none exists" do
    existing = %{
      hostname: "host-a.example",
      ip: nil,
      type: nil,
      tags: %{},
      discovery_sources: []
    }

    update =
      ManualDeviceCreator.additional_update_attrs(existing, %{
        hostname: "host-a.example",
        ip: "198.18.1.2",
        type: "rids",
        type_id: 0,
        tags: %{"source" => "rids"},
        discovery_sources: ["manual"]
      })

    assert update.ip == "198.18.1.2"
    assert update.type == "rids"
    assert update.type_id == 0
    assert update.tags == %{"source" => "rids"}
  end

  test "additional_update_attrs applies a known incoming type" do
    existing = %{hostname: "edge", ip: "192.0.2.8", type: nil, tags: %{}, discovery_sources: []}

    update =
      ManualDeviceCreator.additional_update_attrs(existing, %{
        type: "router",
        type_id: 12,
        tags: %{}
      })

    assert update.type == "router"
    assert update.type_id == 12
  end
end
