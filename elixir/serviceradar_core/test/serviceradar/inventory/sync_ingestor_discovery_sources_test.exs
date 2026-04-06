defmodule ServiceRadar.Inventory.SyncIngestorDiscoverySourcesTest do
  @moduledoc """
  Tests for discovery_sources propagation through the sync ingestor.

  In schema-agnostic mode, the DB schema is set by CNPG search_path credentials.
  Tests use TestSupport for schema isolation.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Camera.InventoryIngestor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.SyncIngestor

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:discovery_sources_test)

    {:ok, actor: actor}
  end

  describe "discovery_sources propagation" do
    test "device discovered by armis has discovery_sources populated", %{
      actor: actor
    } do
      armis_id = "armis-#{System.unique_integer([:positive])}"
      ip = "10.0.2.#{unique_octet()}"

      update = %{
        "ip" => ip,
        "mac" => unique_mac(),
        "hostname" => "armis-device",
        "source" => "armis",
        "metadata" => %{"armis_device_id" => armis_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      assert device.discovery_sources == ["armis"]
    end

    test "device discovered by netbox has discovery_sources populated", %{
      actor: actor
    } do
      netbox_id = "netbox-#{System.unique_integer([:positive])}"
      ip = "10.0.3.#{unique_octet()}"

      update = %{
        "ip" => ip,
        "mac" => unique_mac(),
        "hostname" => "netbox-device",
        "source" => "netbox",
        "metadata" => %{"netbox_device_id" => netbox_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      assert device.discovery_sources == ["netbox"]
    end

    test "device discovered by multiple sources has merged discovery_sources", %{
      actor: actor
    } do
      armis_id = "armis-#{System.unique_integer([:positive])}"
      netbox_id = "netbox-#{System.unique_integer([:positive])}"
      ip = "10.0.4.#{unique_octet()}"
      mac = unique_mac()

      # First discovery from armis
      armis_update = %{
        "ip" => ip,
        "mac" => unique_mac(),
        "hostname" => "multi-source-device",
        "source" => "armis",
        "metadata" => %{"armis_device_id" => armis_id}
      }

      assert :ok = SyncIngestor.ingest_updates([armis_update], actor: actor)

      # Second discovery from netbox (same device by MAC)
      netbox_update = %{
        "ip" => ip,
        "mac" => mac,
        "hostname" => "multi-source-device",
        "source" => "netbox",
        "metadata" => %{"netbox_device_id" => netbox_id}
      }

      assert :ok = SyncIngestor.ingest_updates([netbox_update], actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      # Should have both sources, order may vary
      assert Enum.sort(device.discovery_sources) == ["armis", "netbox"]
    end

    test "device without source field gets 'unknown' as discovery_source", %{
      actor: actor
    } do
      ip = "10.0.5.#{unique_octet()}"

      update = %{
        "ip" => ip,
        "mac" => unique_mac(),
        "hostname" => "unknown-source-device"
        # No "source" field
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      assert "unknown" in device.discovery_sources
    end

    test "duplicate source updates do not create duplicate entries", %{
      actor: actor
    } do
      armis_id = "armis-#{System.unique_integer([:positive])}"
      ip = "10.0.6.#{unique_octet()}"

      update = %{
        "ip" => ip,
        "mac" => unique_mac(),
        "hostname" => "dup-source-device",
        "source" => "armis",
        "metadata" => %{"armis_device_id" => armis_id}
      }

      # Ingest the same update twice
      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      # Should only have one "armis" entry, not duplicated
      assert device.discovery_sources == ["armis"]
    end

    test "device update action accepts discovery_sources for camera inventory merges", %{
      actor: actor
    } do
      uid = "camera-device-#{System.unique_integer([:positive])}"

      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: uid,
            type: "camera",
            type_id: 7,
            name: "Front Door",
            mac: unique_mac(),
            discovery_sources: ["agent"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, updated_device} =
        device
        |> Ash.Changeset.for_update(
          :update,
          %{discovery_sources: ["agent", "camera_plugin"]},
          actor: actor
        )
        |> Ash.update()

      assert Enum.sort(updated_device.discovery_sources) == ["agent", "camera_plugin"]
    end

    test "mapper scanner agent_id is not used as device identifier", %{actor: actor} do
      scanner_agent_id = "mapper-agent-#{System.unique_integer([:positive])}"
      ip_a = "10.0.7.#{unique_octet()}"
      ip_b = "10.0.8.#{unique_octet()}"

      update_a = %{
        "ip" => ip_a,
        "mac" => unique_mac(),
        "hostname" => "mapper-a",
        "source" => "mapper",
        "metadata" => %{"agent_id" => scanner_agent_id}
      }

      update_b = %{
        "ip" => ip_b,
        "mac" => unique_mac(),
        "hostname" => "mapper-b",
        "source" => "mapper",
        "metadata" => %{"agent_id" => scanner_agent_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update_a], actor: actor)
      assert :ok = SyncIngestor.ingest_updates([update_b], actor: actor)

      {:ok, devices_a} =
        Device
        |> Ash.Query.filter(ip == ^ip_a)
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      {:ok, devices_b} =
        Device
        |> Ash.Query.filter(ip == ^ip_b)
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      assert length(devices_a) == 1
      assert length(devices_b) == 1
      refute hd(devices_a).uid == hd(devices_b).uid

      query =
        Ash.Query.for_read(DeviceIdentifier, :lookup, %{
          identifier_type: :agent_id,
          identifier_value: scanner_agent_id,
          partition: "default"
        })

      assert {:ok, []} = query |> Ash.read(actor: actor) |> Page.unwrap()
    end

    test "single batch with same IP resolves to one active device", %{actor: actor} do
      ip = "10.0.9.#{unique_octet()}"
      armis_id = "armis-batch-#{System.unique_integer([:positive])}"

      armis_update = %{
        "ip" => ip,
        "mac" => unique_mac(),
        "hostname" => "same-ip-armis",
        "source" => "armis",
        "metadata" => %{"armis_device_id" => armis_id}
      }

      mapper_update = %{
        "ip" => ip,
        "hostname" => "same-ip-mapper",
        "source" => "mapper",
        "metadata" => %{}
      }

      assert :ok = SyncIngestor.ingest_updates([armis_update, mapper_update], actor: actor)

      {:ok, devices} =
        Device
        |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      assert length(devices) == 1
    end

    test "camera inventory ingest enriches missing ip and hostname from peer device with same mac",
         %{actor: actor} do
      mac = unique_mac()
      camera_uid = "camera-peer-#{System.unique_integer([:positive])}"
      peer_uid = "peer-device-#{System.unique_integer([:positive])}"
      ip = "10.0.10.#{unique_octet()}"

      {:ok, _peer_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: peer_uid,
            name: "Front Door Peer",
            hostname: "front-door.local",
            ip: ip,
            mac: mac,
            vendor_name: "Ubiquiti",
            model: "G5 Bullet",
            discovery_sources: ["mapper"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _camera_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: camera_uid,
            type: "camera",
            type_id: 7,
            name: "Front Door",
            mac: mac,
            discovery_sources: ["camera_plugin"]
          },
          actor: actor
        )
        |> Ash.create()

      payload = %{
        "camera_descriptors" => [
          %{
            "device_uid" => camera_uid,
            "vendor" => "ubiquiti",
            "camera_id" => "protect-front-door",
            "display_name" => "Front Door",
            "identity" => %{"mac" => mac},
            "source_url" => "rtsps://192.168.1.1:7441/front-door",
            "stream_profiles" => [%{"profile_name" => "High", "codec_hint" => "h264"}]
          }
        ]
      }

      assert :ok =
               InventoryIngestor.ingest(payload, %{},
                 actor: actor,
                 resolve_device_uid: fn _descriptor, _status, _actor -> camera_uid end,
                 source_upsert: fn _attrs, _actor -> {:ok, %{id: Ecto.UUID.generate()}} end,
                 profile_upsert: fn attrs, _actor -> {:ok, attrs} end
               )

      {:ok, [updated_camera]} =
        Device
        |> Ash.Query.filter(uid == ^camera_uid and is_nil(deleted_at))
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      assert updated_camera.ip == ip
      assert updated_camera.hostname == "front-door.local"
      assert updated_camera.model == "G5 Bullet"
      assert updated_camera.type == "camera"
    end

    test "camera inventory strong identity claims ip from stale ip-only placeholder", %{
      actor: actor
    } do
      mac = unique_mac()
      ip = "10.0.11.#{unique_octet()}"
      camera_uid = "sr:camera-#{System.unique_integer([:positive])}"
      placeholder_uid = "placeholder-#{System.unique_integer([:positive])}"

      {:ok, _placeholder} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: placeholder_uid,
            ip: ip,
            discovery_sources: ["mapper"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _camera_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: camera_uid,
            type: "camera",
            type_id: 7,
            name: "Front Door",
            discovery_sources: ["camera_plugin"]
          },
          actor: actor
        )
        |> Ash.create()

      assert :ok =
               IdentityReconciler.register_identifiers(
                 camera_uid,
                 %{mac: mac},
                 actor: actor
               )

      payload = %{
        "camera_descriptors" => [
          %{
            "device_uid" => mac,
            "vendor" => "ubiquiti",
            "camera_id" => "protect-front-door",
            "display_name" => "Front Door",
            "ip" => ip,
            "identity" => %{"mac" => mac},
            "source_url" => "rtsps://192.168.1.1:7441/front-door",
            "stream_profiles" => [%{"profile_name" => "High", "codec_hint" => "h264"}]
          }
        ]
      }

      assert :ok =
               InventoryIngestor.ingest(payload, %{},
                 actor: actor,
                 resolve_device_uid: fn _descriptor, _status, _actor -> camera_uid end,
                 source_upsert: fn _attrs, _actor -> {:ok, %{id: Ecto.UUID.generate()}} end,
                 profile_upsert: fn attrs, _actor -> {:ok, attrs} end
               )

      {:ok, [camera_device]} =
        Device
        |> Ash.Query.filter(uid == ^camera_uid and is_nil(deleted_at))
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      assert camera_device.ip == ip
      assert camera_device.type == "camera"

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Device.get_by_uid(placeholder_uid, false, actor: actor)

      {:ok, active_ip_devices} =
        Device
        |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      assert Enum.map(active_ip_devices, & &1.uid) == [camera_uid]
    end
  end

  defp unique_octet do
    rem(System.unique_integer([:positive]), 200) + 10
  end

  defp unique_mac do
    value = System.unique_integer([:positive])

    for_result =
      for shift <- [40, 32, 24, 16, 8, 0] do
        value
        |> Bitwise.bsr(shift)
        |> Bitwise.band(0xFF)
        |> Integer.to_string(16)
        |> String.pad_leading(2, "0")
        |> String.upcase()
      end

    Enum.join(for_result, ":")
  end
end
