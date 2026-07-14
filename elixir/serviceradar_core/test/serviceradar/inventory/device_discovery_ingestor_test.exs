defmodule ServiceRadar.Inventory.DeviceDiscoveryIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor

  test "translates plugin device discovery envelopes into inventory updates" do
    parent = self()

    payload = %{
      "status" => "OK",
      "summary" => "discovered wireless inventory",
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "wifi-network-map",
          "collection_id" => "csv-seed-2026-05-01",
          "reference_hash" => "ref-sha",
          "devices" => [
            %{
              "hostname" => "SITE01-MDF001-WAP001",
              "ip" => "192.0.2.249",
              "mac" => "00:00:5e:00:53:01",
              "serial" => "SN0000000001",
              "vendor_name" => "Aruba",
              "model" => "325",
              "type" => "access_point",
              "role" => "ap_bridge",
              "status" => "Up",
              "is_available" => true,
              "location" => %{
                "site_code" => "ZZA",
                "site_name" => "Example Regional Airport",
                "latitude" => 10.0000,
                "longitude" => -20.0000
              }
            }
          ]
        }
      ]
    }

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload, %{partition: "local"},
               actor: :actor,
               device_sync: fn updates, context ->
                 send(parent, {:device_sync, updates, context})
                 :ok
               end
             )

    assert_receive {:device_sync, [update], %{actor: :actor}}
    assert update["source"] == "wifi-network-map"
    assert update["partition"] == "local"
    assert update["hostname"] == "SITE01-MDF001-WAP001"
    assert update["metadata"]["integration_type"] == "plugin_device_discovery"
    assert update["metadata"]["integration_id"] == "wifi-network-map:access_point:SN0000000001"
    assert update["metadata"]["device_type"] == "access_point"
    assert update["metadata"]["device_role"] == "ap_bridge"
    assert update["metadata"]["site_code"] == "ZZA"
    assert update["metadata"]["latitude"] == 10.0000
  end

  describe "integration_id minting" do
    defp ingest_device(device) do
      parent = self()

      payload = %{
        "device_discovery" => [
          %{
            "schema" => "serviceradar.device_discovery.v1",
            "source" => "test-source",
            "devices" => [device]
          }
        ]
      }

      assert :ok =
               DeviceDiscoveryIngestor.ingest(payload, %{partition: "local"},
                 actor: :actor,
                 device_sync: fn updates, context ->
                   send(parent, {:device_sync, updates, context})
                   :ok
                 end
               )

      assert_receive {:device_sync, [update], %{actor: :actor}}
      update
    end

    test "prefers serial over every other key" do
      update =
        ingest_device(%{
          "type" => "camera",
          "serial" => "SER123",
          "uuid" => "9c3f9f2a-0000-4000-8000-000000000001",
          "hostname" => "cam-01",
          "mac" => "00:00:5e:00:53:01",
          "ip" => "10.0.0.5"
        })

      assert update["metadata"]["integration_id"] == "test-source:camera:SER123"
    end

    test "prefers stable hardware id over hostname and MAC when serial is absent" do
      update =
        ingest_device(%{
          "type" => "camera",
          "uuid" => "9c3f9f2a-0000-4000-8000-000000000001",
          "hostname" => "cam-01",
          "mac" => "00:00:5e:00:53:01",
          "ip" => "10.0.0.5"
        })

      assert update["metadata"]["integration_id"] ==
               "test-source:camera:9c3f9f2a-0000-4000-8000-000000000001"
    end

    test "prefers hostname over MAC so rotating MACs cannot rotate the id" do
      update =
        ingest_device(%{
          "type" => "camera",
          "hostname" => "cam-01",
          "mac" => "00:00:5e:00:53:01",
          "ip" => "10.0.0.5"
        })

      assert update["metadata"]["integration_id"] == "test-source:camera:cam-01"

      rotated =
        ingest_device(%{
          "type" => "camera",
          "hostname" => "cam-01",
          "mac" => "de:ad:be:ef:00:01",
          "ip" => "10.0.0.5"
        })

      assert rotated["metadata"]["integration_id"] == update["metadata"]["integration_id"]
    end

    test "uses the first valid normalized MAC when MAC is the only key" do
      update = ingest_device(%{"type" => "camera", "mac" => "00:00:5e:00:53:01"})

      assert update["metadata"]["integration_id"] == "test-source:camera:00005E005301"

      # Format variations and multi-value blobs cannot rotate the id.
      for mac <- ["00-00-5E-00-53-01", "0000.5e00.5301", "00:00:5e:00:53:01,de:ad:be:ef:00:01"] do
        variant = ingest_device(%{"type" => "camera", "mac" => mac})

        assert variant["metadata"]["integration_id"] == update["metadata"]["integration_id"],
               "MAC variant #{inspect(mac)} rotated the integration_id"
      end
    end

    test "mints no integration_id from an invalid MAC" do
      update = ingest_device(%{"type" => "camera", "mac" => "not-a-mac", "ip" => "10.0.0.9"})

      refute Map.has_key?(update["metadata"], "integration_id")
    end
  end

  test "ignores plugin results without device discovery envelopes" do
    parent = self()

    assert :ok =
             DeviceDiscoveryIngestor.ingest(%{"status" => "OK"}, %{},
               actor: :actor,
               device_sync: fn updates, context ->
                 send(parent, {:unexpected_device_sync, updates, context})
                 :ok
               end
             )

    refute_received {:unexpected_device_sync, _, _}
  end

  test "advertises support only for device discovery payloads" do
    discovery = %{
      "device_discovery" => [
        %{"schema" => "serviceradar.device_discovery.v1", "devices" => []}
      ]
    }

    assert DeviceDiscoveryIngestor.supports?(discovery, %{})
    assert DeviceDiscoveryIngestor.supports?([%{"summary" => "ignored"}, discovery], %{})
    refute DeviceDiscoveryIngestor.supports?(%{"events" => [%{"kind" => "camera"}]}, %{})
    refute DeviceDiscoveryIngestor.supports?("not a payload", %{})
  end

  test "reconciles AWX memberships only after device sync succeeds" do
    parent = self()

    payload = %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "awx",
          "devices" => [%{"device_id" => "awx:controller:host:100", "hostname" => "node-1"}]
        }
      ]
    }

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload, %{},
               actor: :actor,
               device_sync: fn _updates, _context ->
                 send(parent, :device_sync_finished)
                 :ok
               end,
               membership_sync: fn ^payload, %{actor: :actor} ->
                 send(parent, :membership_sync_started)
                 :ok
               end
             )

    assert_receive :device_sync_finished
    assert_receive :membership_sync_started
  end

  test "does not reconcile memberships when device sync fails" do
    parent = self()
    payload = awx_payload_with_device()

    assert {:error, :device_sync_failed} =
             DeviceDiscoveryIngestor.ingest(payload, %{},
               actor: :actor,
               device_sync: fn _updates, _context -> {:error, :device_sync_failed} end,
               membership_sync: fn _payload, _context ->
                 send(parent, :unexpected_membership_sync)
                 :ok
               end
             )

    refute_received :unexpected_membership_sync
  end

  test "complete empty aggregates can reconcile absence without a device write" do
    parent = self()

    payload = %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "awx",
          "devices" => []
        }
      ]
    }

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload, %{},
               actor: :actor,
               device_sync: fn _updates, _context ->
                 send(parent, :unexpected_device_sync)
                 :ok
               end,
               membership_sync: fn ^payload, %{actor: :actor} ->
                 send(parent, :empty_membership_sync)
                 :ok
               end
             )

    refute_received :unexpected_device_sync
    assert_receive :empty_membership_sync
  end

  describe "proxmox canonical identity metadata passthrough" do
    alias ServiceRadar.Inventory.IdentityReconciler
    alias ServiceRadar.Inventory.Sync.Normalize

    # Locks in the cross-language contract the proxmox wasm plugin's discovery
    # envelope now relies on: a device carrying the canonical v2 integration_id,
    # every configured NIC MAC, and lookup-only legacy bridges must flow through
    # into resolvable strong identifiers, so a renamed / multi-NIC proxmox guest
    # reconciles onto ONE device instead of a name-keyed duplicate.
    test "carries v2 integration_id, all MACs, and legacy bridges into strong identifiers" do
      parent = self()

      payload = %{
        "status" => "OK",
        "device_discovery" => [
          %{
            "schema" => "serviceradar.device_discovery.v1",
            "source" => "proxmox",
            "devices" => [
              %{
                "device_id" => "proxmox:qemu:100",
                "hostname" => "web01",
                "ip" => "192.168.2.15",
                "mac" => "BC:24:11:76:DF:7E",
                "type" => "vm",
                "metadata" => %{
                  "integration_id" => "proxmox:v2:lab:vm:100",
                  "mac_addresses" => ["BC:24:11:76:DF:7E", "BC:24:11:AA:BB:CC"],
                  "legacy_integration_ids" => [
                    "proxmox:guest:pve-a:qemu:100",
                    "proxmox:vm:100",
                    "proxmox:vm:qemu/100"
                  ]
                }
              }
            ]
          }
        ]
      }

      assert :ok =
               DeviceDiscoveryIngestor.ingest(payload, %{partition: "default"},
                 actor: :actor,
                 device_sync: fn updates, _context ->
                   send(parent, {:device_sync, updates})
                   :ok
                 end
               )

      assert_receive {:device_sync, [update]}

      # The plugin's canonical id wins over the ingestor's name-based fallback.
      assert update["metadata"]["integration_id"] == "proxmox:v2:lab:vm:100"
      assert update["metadata"]["mac_addresses"] == ["BC:24:11:76:DF:7E", "BC:24:11:AA:BB:CC"]
      assert "proxmox:vm:100" in update["metadata"]["legacy_integration_ids"]

      ids =
        update
        |> Normalize.normalize_update()
        |> IdentityReconciler.extract_strong_identifiers()

      assert ids.integration_id == "proxmox:v2:lab:vm:100"
      assert Enum.sort(ids.macs) == Enum.sort(["BC241176DF7E", "BC2411AABBCC"])
      assert "proxmox:vm:100" in ids.legacy_integration_ids
      assert "proxmox:guest:pve-a:qemu:100" in ids.legacy_integration_ids
    end
  end

  describe "AWX ansible_host IP recovery" do
    alias ServiceRadar.Inventory.IdentityReconciler
    alias ServiceRadar.Inventory.Sync.Normalize

    defp ingest_awx_host(device) do
      parent = self()

      payload = %{
        "status" => "OK",
        "device_discovery" => [
          %{
            "schema" => "serviceradar.device_discovery.v1",
            "source" => "awx",
            "devices" => [device]
          }
        ]
      }

      assert :ok =
               DeviceDiscoveryIngestor.ingest(payload, %{partition: "default"},
                 actor: :actor,
                 device_sync: fn updates, _context ->
                   send(parent, {:device_sync, updates})
                   :ok
                 end
               )

      assert_receive {:device_sync, [update]}
      update
    end

    # The AWX inventory-sync plugin captures the raw host `variables` as a
    # stringified JSON object under `metadata.awx.variables` but (under TinyGo)
    # can leave `ip` empty. This nested blob mirrors the live demo shape that
    # trips the plugin's minimal JSON decoder; the ingestor must recover the IP.
    @awx_variables_json ~s({"ansible_host": "192.168.2.235", ) <>
                          ~s("proxmox_agent_interfaces": [{"name": "eth0", ) <>
                          ~s("ip_addresses": ["192.168.2.235/24"]}], "ansible_user": "root"})

    test "recovers the canonical IP from ansible_host in stringified variables" do
      update =
        ingest_awx_host(%{
          "device_id" => "awx:ctrl-1:host:42",
          "hostname" => "alma-test",
          "type" => "host",
          "role" => "ansible_host",
          "metadata" => %{
            "awx" => %{
              "controller_id" => "ctrl-1",
              "host_id" => 42,
              "host_name" => "alma-test",
              "variables" => @awx_variables_json
            }
          }
        })

      # The decoded ansible_host becomes the device's canonical IP...
      assert update["ip"] == "192.168.2.235"

      # ...and flows into the SAME strong-identifier/reconciliation path other
      # sources use, so DIRE resolves the AWX device against same-IP hosts.
      ids =
        update
        |> Normalize.normalize_update()
        |> IdentityReconciler.extract_strong_identifiers()

      assert ids.ip == "192.168.2.235"
      assert ids.integration_id == "awx:host:alma-test"
    end

    test "recovers ansible_host from the legacy ansible_ssh_host key" do
      update =
        ingest_awx_host(%{
          "device_id" => "awx:ctrl-1:host:43",
          "hostname" => "ns01",
          "metadata" => %{
            "awx" => %{"variables" => ~s({"ansible_ssh_host": "192.168.2.44"})}
          }
        })

      assert update["ip"] == "192.168.2.44"
    end

    test "does not fabricate an IP for a host with no ansible_host" do
      update =
        ingest_awx_host(%{
          "device_id" => "awx:ctrl-1:host:99",
          "hostname" => "localhost",
          "metadata" => %{
            "awx" => %{"variables" => ~s({"ansible_connection": "local"})}
          }
        })

      assert is_nil(update["ip"])
    end

    test "does not treat a non-IP ansible_host as an IP" do
      update =
        ingest_awx_host(%{
          "device_id" => "awx:ctrl-1:host:100",
          "hostname" => "freebsd-01",
          "metadata" => %{
            "awx" => %{"variables" => ~s({"ansible_host": "freebsd-01.lab.example.com"})}
          }
        })

      assert is_nil(update["ip"])
    end

    test "prefers an explicit device ip over the ansible_host fallback" do
      update =
        ingest_awx_host(%{
          "device_id" => "awx:ctrl-1:host:101",
          "hostname" => "dusk01",
          "ip" => "10.9.9.9",
          "metadata" => %{
            "awx" => %{"variables" => @awx_variables_json}
          }
        })

      assert update["ip"] == "10.9.9.9"
    end

    test "tolerates a malformed variables blob without crashing" do
      update =
        ingest_awx_host(%{
          "device_id" => "awx:ctrl-1:host:102",
          "hostname" => "broken-01",
          "metadata" => %{
            "awx" => %{"variables" => "not-json: [oops"}
          }
        })

      assert is_nil(update["ip"])
    end
  end

  defp awx_payload_with_device do
    %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "awx",
          "devices" => [%{"device_id" => "awx:controller:host:100", "hostname" => "node-1"}]
        }
      ]
    }
  end
end
