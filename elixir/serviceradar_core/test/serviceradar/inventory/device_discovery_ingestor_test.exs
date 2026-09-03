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

  test "lifts OpenText Network Automation os, hardware, owner, and managed flags onto the inventory update" do
    parent = self()

    payload = %{
      "status" => "OK",
      "summary" => "OpenText Network Automation inventory collected: 1 devices",
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "opentext-nom",
          "collection_id" => "col-1",
          "devices" => [
            %{
              "device_id" => "71061",
              "hostname" => "SITE02-MDF001-CSW001",
              "ip" => "10.7.84.1",
              "serial" => "VN4BM3P0W5",
              "vendor_name" => "Aruba",
              "model" => "JL659A 6300M",
              "type" => "Switch",
              "status" => "Managed",
              "is_available" => true,
              "location" => %{"site_name" => "Example Production"},
              "labels" => %{
                "discovery_source" => "opentext-nom",
                "inventory_source" => "opentext-nom"
              },
              "metadata" => %{
                "integration_id" => "opentext-nom:v1:network-automation-prod:device:71061",
                "integration_type" => "opentext-nom",
                "is_managed" => true,
                "os" => %{"name" => "ArubaOS-CX", "version" => "FL.10.13.1161"},
                "hw_info" => %{
                  "serial_number" => "VN4BM3P0W5",
                  "chassis_serials" => ["VN4BM3P0W5", "VN4BM3P0X3"],
                  "memory_bytes" => 7_973_057_331,
                  "total_ports" => 120
                },
                "owner" => %{"name" => "Example NOC"},
                "source_metadata" => %{"geographical_location" => "TPECS_MDF1"}
              }
            }
          ]
        }
      ]
    }

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload, %{partition: "default"},
               actor: :actor,
               device_sync: fn updates, context ->
                 send(parent, {:device_sync, updates, context})
                 :ok
               end
             )

    assert_receive {:device_sync, [update], %{actor: :actor}}
    assert update["is_managed"] == true
    assert update["os"]["name"] == "ArubaOS-CX"
    assert update["os"]["version"] == "FL.10.13.1161"
    assert update["hw_info"]["serial_number"] == "VN4BM3P0W5"
    assert update["hw_info"]["chassis_serials"] == ["VN4BM3P0W5", "VN4BM3P0X3"]
    assert update["hw_info"]["memory_bytes"] == 7_973_057_331
    assert update["owner"]["name"] == "Example NOC"
    assert update["tags"]["inventory_source"] == "opentext-nom"
    assert update["metadata"]["os_name"] == "ArubaOS-CX"
    assert update["metadata"]["geographical_location"] == "TPECS_MDF1"
  end

  test "forwards plugin facts without dropping source metadata" do
    parent = self()

    payload = %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "opentext-nom",
          "metadata" => %{"source_instance" => "network-automation-prod"},
          "devices" => [
            %{
              "hostname" => "kiosk-1",
              "ip" => "10.100.159.26",
              "mac" => "00:09:EC:02:83:7E",
              "metadata" => %{
                "facts" => %{
                  "switch_port_attachment" => %{
                    "switch_hostname" => "SITE01-IDFC08-ASW002",
                    "port" => "3/1/28"
                  }
                },
                "opentext_nom_access_switch" => "SITE01-IDFC08-ASW002:3/1/28"
              }
            }
          ]
        }
      ]
    }

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload, %{partition: "default"},
               actor: :actor,
               device_sync: fn updates, context ->
                 send(parent, {:device_sync, updates, context})
                 :ok
               end
             )

    assert_receive {:device_sync, [update], %{actor: :actor}}
    assert update["facts"]["switch_port_attachment"]["port"] == "3/1/28"
    assert update["source_instance"] == "network-automation-prod"
    assert update["metadata"]["opentext_nom_access_switch"] == "SITE01-IDFC08-ASW002:3/1/28"
  end

  test "preserves unmanaged HPNA devices as is_managed false" do
    parent = self()

    payload = %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "opentext-nom",
          "devices" => [
            %{
              "hostname" => "inactive-sw",
              "ip" => "10.0.0.2",
              "status" => "Unmanaged",
              "metadata" => %{"is_managed" => false, "integration_id" => "na:device:2"}
            }
          ]
        }
      ]
    }

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload, %{},
               actor: :actor,
               device_sync: fn updates, _context ->
                 send(parent, {:device_sync, updates})
                 :ok
               end
             )

    assert_receive {:device_sync, [update]}
    assert update["is_managed"] == false
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

  test "routes a complete plugin inventory collection through device sync before source activation" do
    parent = self()

    payload = %{
      "status" => "OK",
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "example-inventory",
          "collection_id" => "example-collection-1",
          "reference_hash" => String.duplicate("a", 64),
          "observed_at" => "2026-07-13T18:00:00Z",
          "metadata" => %{
            "source_instance" => "example-prod",
            "snapshot_complete" => true,
            "query_hash" => String.duplicate("b", 64)
          },
          "devices" => [
            %{
              "device_id" => "201",
              "hostname" => "iad-asw-01",
              "ip" => "192.0.2.20",
              "serial" => "FOC1234ABC",
              "vendor_name" => "Cisco",
              "metadata" => %{
                "integration_id" => "example-inventory:v1:example-prod:device:201",
                "integration_type" => "example-inventory",
                "source_metadata" => %{
                  "instance_id" => "example-prod",
                  "partition" => "IAD"
                }
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
               end,
               source_observation_preflight: fn envelope, updates, context ->
                 send(parent, {:source_preflight, envelope, updates, context})
                 {:ok, :process}
               end,
               source_observation_sync: fn envelope, updates, context ->
                 send(parent, {:source_sync, envelope, updates, context})
                 :ok
               end
             )

    assert_receive {:source_preflight, preflight_envelope, [preflight_update], preflight_context}
    assert preflight_envelope["collection_id"] == "example-collection-1"
    assert preflight_update["source"] == "example-inventory"
    assert preflight_context == %{actor: :actor, partition: "default"}

    assert_receive {:device_sync, [update]}
    assert update["source"] == "example-inventory"
    assert update["metadata"]["integration_type"] == "example-inventory"
    assert update["metadata"]["serial_number"] == "FOC1234ABC"

    assert_receive {:source_sync, envelope, [^update], context}
    assert envelope["collection_id"] == "example-collection-1"
    assert context == %{actor: :actor, partition: "default"}
  end

  test "rejects stale plugin inventory collections before canonical device sync" do
    parent = self()

    payload = %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "example-inventory",
          "devices" => [
            %{"device_id" => "example-inventory:v1:lab:device:1", "hostname" => "iad-asw-01"}
          ]
        }
      ]
    }

    assert {:error, :stale_source_snapshot} =
             DeviceDiscoveryIngestor.ingest(payload, %{partition: "default"},
               actor: :actor,
               source_observation_preflight: fn _envelope, _updates, _context ->
                 {:error, :stale_source_snapshot}
               end,
               device_sync: fn _updates, _context ->
                 send(parent, :unexpected_device_sync)
                 :ok
               end,
               source_observation_sync: fn _envelope, _updates, _context ->
                 send(parent, :unexpected_source_sync)
                 :ok
               end
             )

    refute_received :unexpected_device_sync
    refute_received :unexpected_source_sync
  end

  test "idempotent plugin inventory collections skip canonical and source writes" do
    parent = self()

    payload = %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "example-inventory",
          "devices" => [
            %{"device_id" => "example-inventory:v1:lab:device:1", "hostname" => "iad-asw-01"}
          ]
        }
      ]
    }

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload, %{partition: "default"},
               actor: :actor,
               source_observation_preflight: fn _envelope, _updates, _context ->
                 {:ok, :idempotent}
               end,
               device_sync: fn _updates, _context ->
                 send(parent, :unexpected_device_sync)
                 :ok
               end,
               source_observation_sync: fn _envelope, _updates, _context ->
                 send(parent, :unexpected_source_sync)
                 :ok
               end
             )

    refute_received :unexpected_device_sync
    refute_received :unexpected_source_sync
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

  test "reconciles source observations before AWX memberships" do
    parent = self()

    payload = %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "awx",
          "collection_id" => "awx-collection-1",
          "devices" => [%{"device_id" => "awx:controller:host:100", "hostname" => "node-1"}]
        }
      ]
    }

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload, %{partition: "default"},
               actor: :actor,
               source_observation_preflight: fn _envelope, _updates, _context ->
                 send(parent, {:phase, :source_preflight})
                 {:ok, :process}
               end,
               device_sync: fn _updates, _context ->
                 send(parent, {:phase, :device_sync})
                 :ok
               end,
               source_observation_sync: fn _envelope, _updates, _context ->
                 send(parent, {:phase, :source_sync})
                 :ok
               end,
               membership_sync: fn ^payload, %{actor: :actor} ->
                 send(parent, {:phase, :membership_sync})
                 :ok
               end
             )

    phases =
      for _ <- 1..4 do
        assert_receive {:phase, phase}
        phase
      end

    assert phases == [:source_preflight, :device_sync, :source_sync, :membership_sync]
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

    # Current plugin payload: `1856332974` stopped emitting `metadata.awx.variables`
    # (secret-capable) and stamps the extracted value on `metadata.awx.ansible_host`.
    # `ip` is blank when the plugin could not copy that value onto the device IP
    # field. Recovery that only reads `variables` never fires on this shape.
    test "recovers the canonical IP from metadata.awx.ansible_host when ip is blank" do
      update =
        ingest_awx_host(%{
          "device_id" => "awx:ctrl-1:host:42",
          "hostname" => "alma-test",
          "ip" => "",
          "type" => "host",
          "role" => "ansible_host",
          "metadata" => %{
            "integration_id" => "awx:v2:ctrl-1:host:42",
            "awx" => %{
              "controller_id" => "ctrl-1",
              "host_id" => 42,
              "host_name" => "alma-test",
              "ansible_host" => "192.168.2.235"
            }
          }
        })

      assert update["ip"] == "192.168.2.235"

      ids =
        update
        |> Normalize.normalize_update()
        |> IdentityReconciler.extract_strong_identifiers()

      assert ids.ip == "192.168.2.235"
      assert ids.integration_id == "awx:v2:ctrl-1:host:42"
    end

    test "does not treat a DNS metadata.awx.ansible_host as an IP" do
      update =
        ingest_awx_host(%{
          "device_id" => "awx:ctrl-1:host:100",
          "hostname" => "freebsd-01",
          "ip" => "",
          "metadata" => %{
            "awx" => %{"ansible_host" => "freebsd-01.lab.example.com"}
          }
        })

      assert is_nil(update["ip"])
    end

    # Older in-flight payloads still wrap ansible_host in a stringified
    # `variables` blob. Keep recovering from that shape until those are gone.
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
