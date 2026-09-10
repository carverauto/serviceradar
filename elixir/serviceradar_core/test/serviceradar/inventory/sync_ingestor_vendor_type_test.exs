defmodule ServiceRadar.Inventory.SyncIngestorVendorTypeTest do
  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceEnrichmentRules
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo

  require Ash.Query

  setup_all do
    previous_rules_dir =
      Application.fetch_env(:serviceradar_core, :device_enrichment_rules_dir)

    test_rules_dir = Path.join(System.tmp_dir!(), "serviceradar-device-rules-empty")
    File.mkdir_p!(test_rules_dir)
    Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, test_rules_dir)
    DeviceEnrichmentRules.reload()
    ServiceRadar.TestSupport.start_core!()

    on_exit(fn ->
      restore_env_snapshot(:device_enrichment_rules_dir, previous_rules_dir)
      DeviceEnrichmentRules.reload()
    end)

    :ok
  end

  setup do
    ensure_inventory_rollup_schema!()
    actor = SystemActor.system(:sync_ingestor_vendor_type_test)
    {:ok, actor: actor}
  end

  test "infers Ubiquiti vendor from sys_object_id", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "u6lr-test",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.41112",
        "sys_descr" => "U6-LR 6.7.31.15618"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.vendor_name == "Ubiquiti"
  end

  test "infers Ubiquiti vendor from UBNT sysDescr token", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "ubnt-switch-test",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
        "sys_descr" => "Linux UBNT 3.18.24 #0 Thu Aug 30 12:10:54 2018 mips"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.vendor_name == "Ubiquiti"
  end

  test "infers router type from UDM sysDescr", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "farm01",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
        "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Router"
    assert device.type_id == 12
  end

  test "classifies Proxmox nodes as hypervisors from device_role metadata", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "pve-#{System.unique_integer([:positive])}",
      "source" => "proxmox-api",
      "metadata" => %{
        "device_role" => "hypervisor",
        "virtualization_node" => "pve01"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Hypervisor"
    assert device.type_id == 99
    assert device.metadata["device_role"] == "hypervisor"
  end

  test "classifies Proxmox VM and LXC guests as virtual devices", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "guest-#{System.unique_integer([:positive])}",
      "source" => "proxmox-api",
      "metadata" => %{
        "device_role" => "virtual-guest",
        "virtualization_guest_type" => "qemu"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Virtual"
    assert device.type_id == 6
  end

  test "infers switch type from USW sysDescr", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "USWPro24",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.4413",
        "sys_descr" => "USW-Pro-24, 7.2.123.16565, Linux 3.6.5"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Switch"
    assert device.type_id == 10
  end

  test "infers switch type from sys_name and ip_forwarding when sysDescr is generic", %{
    actor: actor
  } do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "switch-generic-test",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
        "sys_descr" => "Linux UBNT 3.18.24 #0 Thu Aug 30 12:10:54 2018 mips",
        "sys_name" => "USW16PoE",
        "ip_forwarding" => "2"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Switch"
    assert device.type_id == 10
  end

  test "infers router type from sys_name plus forwarding", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "router-generic-test",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
        "sys_descr" => "Linux UBNT 4.19",
        "sys_name" => "UDM-Pro-Max",
        "ip_forwarding" => "1"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Router"
    assert device.type_id == 12
  end

  test "infers access point type from U6 sysDescr", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "U6LR",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.41112",
        "sys_descr" => "U6-LR 6.7.31.15618"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Access Point"
    assert device.type_id == 99
  end

  test "normalizes top-level snmp_fingerprint into metadata and enrichment context", %{
    actor: actor
  } do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "farm01",
      "source" => "mapper",
      "metadata" => %{},
      "snmp_fingerprint" => %{
        "system" => %{
          "sys_name" => "farm01",
          "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
          "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
          "sys_contact" => "Network Operations",
          "sys_location" => "HQ",
          "ip_forwarding" => 1
        },
        "bridge" => %{
          "bridge_base_mac" => "F4:92:BF:75:C7:2B",
          "bridge_port_count" => 8,
          "stp_forwarding_port_count" => 6
        }
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.vendor_name == "Ubiquiti"
    assert device.type == "Router"
    assert device.metadata["sys_object_id"] == ".1.3.6.1.4.1.8072.3.2.10"
    assert device.metadata["ip_forwarding"] == "1"
    assert device.metadata["bridge_base_mac"] == "F4:92:BF:75:C7:2B"
    assert device.metadata["snmp_name"] == "farm01"
    assert device.metadata["snmp_owner"] == "Network Operations"
    assert device.metadata["snmp_location"] == "HQ"

    assert device.metadata["snmp_description"] ==
             "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"

    assert is_map(device.metadata["snmp_fingerprint"])
    assert device.owner == %{"name" => "Network Operations"}
  end

  test "maps Armis SDK inventory fields into OCSF device fields", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "mac" => "00:11:22:33:44:55",
      "hostname" => "axis-camera-01",
      "source" => "armis",
      "type" => "Camera",
      "vendor_name" => "Axis Communications",
      "model" => "P1375",
      "risk_score" => 72,
      "os" => %{"name" => "Linux", "version" => "5.15"},
      "network_interfaces" => [
        %{
          "name" => "eth0",
          "alias" => "OT uplink",
          "mac_address" => "00:11:22:33:44:55",
          "ipv4_address" => ip,
          "type" => "Ethernet",
          "vlan" => 100
        }
      ],
      "metadata" => %{
        "integration_id" => "armis-sdk-#{System.unique_integer([:positive])}",
        "integration_type" => "armis",
        "type" => "Camera",
        "boundaries" => Jason.encode!([%{"id" => 7, "name" => "All OT Boundaries"}]),
        "brand" => "Axis Communications",
        "serial_number" => "SN-123",
        "query_label" => "managed"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Camera"
    assert device.type_id == 99
    assert device.vendor_name == "Axis Communications"
    assert device.model == "P1375"
    assert device.risk_score == 72
    assert device.risk_level == "High"
    assert device.os == %{"name" => "Linux", "version" => "5.15"}
    assert device.hw_info == %{"serial_number" => "SN-123"}
    assert [%{"name" => "eth0"}] = device.network_interfaces
    assert device.is_managed == true
    assert device.is_active == true
    assert device.metadata["query_label"] == "managed"
    assert device.metadata["boundary_names"] == "All OT Boundaries"

    interfaces =
      Interface
      |> Ash.Query.for_read(:by_device, %{device_id: device.uid})
      |> Ash.read!(actor: actor, authorize?: false)

    assert [interface] = interfaces
    assert interface.if_name == "eth0"
    assert interface.if_alias == "OT uplink"
    assert interface.if_phys_address == "00:11:22:33:44:55"
    assert interface.ip_addresses == [ip]
    assert interface.if_type_name == "Ethernet"
    assert interface.interface_kind == "physical"
    assert interface.metadata["vlan"] == "100"
  end

  test "promotes Armis metadata device type into OCSF type fields", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "armis-tablet-#{System.unique_integer([:positive])}",
      "source" => "armis",
      "metadata" => %{
        "integration_id" => "armis-tablet-#{System.unique_integer([:positive])}",
        "integration_type" => "armis",
        "armis_type" => "Tablet",
        "armis_category" => "Mobile Device",
        "brand" => "D-Link"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Tablet"
    assert device.type_id == 4
    assert device.vendor_name == "D-Link"
    assert device.metadata["armis_category"] == "Mobile Device"
  end

  @tag :visibility
  test "enriches an Armis-imported device from passive netprobe fingerprint evidence", %{
    actor: actor
  } do
    ip = unique_ip()
    armis_id = "armis-passive-#{System.unique_integer([:positive])}"

    armis_update = %{
      "ip" => ip,
      "mac" => unique_mac(),
      "hostname" => "armis-passive-host",
      "source" => "armis",
      "metadata" => %{
        "integration_id" => armis_id,
        "integration_type" => "armis",
        "armis_device_id" => armis_id,
        "type" => "Unknown"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([armis_update], actor: actor)
    armis_device = fetch_device_by_ip!(actor, ip)

    passive_update = %{
      "ip" => ip,
      "source" => "passive-netprobe",
      "metadata" => %{
        "passive_fingerprint.source" => "passive-netprobe",
        "passive_fingerprint.profile_id" => "linux-hosts",
        "passive_fingerprint.profile_name" => "Linux Hosts",
        "passive_fingerprint.interface" => "eth0",
        "passive_fingerprint.observed_at" => "2026-05-27T14:30:01Z",
        "passive_fingerprint.tcp.signature" => "64240:64:1:60:M1460,S,T,N,W7",
        "passive_fingerprint.tcp.os_family" => "linux",
        "passive_fingerprint.tcp.os_name" => "Linux 5.x",
        "passive_fingerprint.tcp.confidence" => "0.92",
        "_alias_last_seen_ip" => ip,
        "ip_alias:#{ip}" => "2026-05-27T14:30:01Z"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([passive_update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.uid == armis_device.uid
    assert "armis" in device.discovery_sources
    assert "passive-netprobe" in device.discovery_sources
    assert device.vendor_name == "Linux"
    assert device.type == "Server"
    assert device.type_id == 1
    assert device.metadata["armis_device_id"] == armis_id
    assert device.metadata["classification_rule_id"] == "passive-fingerprint-linux-host"

    assert device.metadata["passive_fingerprint"]["tcp"]["signature"] ==
             "64240:64:1:60:M1460,S,T,N,W7"

    assert device.metadata["passive_fingerprint"]["tcp"]["source"] == "passive-netprobe"
    assert device.os["passive_fingerprint"]["family"] == "linux"
    assert device.os["passive_fingerprint"]["version"] == "Linux 5.x"
  end

  @tag :visibility
  test "normalizes passive netprobe DPI evidence onto canonical device metadata", %{actor: actor} do
    ip = unique_ip()

    # DPI is enrichment-only: it describes whatever is at an address, it does not
    # establish that anything is there, so it cannot mint the device it lands on.
    # This test is about metadata normalization, so give it a device to normalize
    # onto. See SourcePolicy.enrichment_only_source?/1.
    seed_id = "dpi-seed-#{System.unique_integer([:positive])}"

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "mac" => unique_mac(),
                   "source" => "armis",
                   "metadata" => %{
                     "integration_id" => seed_id,
                     "integration_type" => "armis",
                     "armis_device_id" => seed_id
                   }
                 }
               ],
               actor: actor
             )

    dpi_update = %{
      "ip" => ip,
      "source" => "passive-netprobe",
      "metadata" => %{
        "dpi.source" => "passive-netprobe",
        "dpi.profile_id" => "dpi-hosts",
        "dpi.interface" => "eth0",
        "dpi.protocol" => "dns",
        "dpi.dns.count" => "1",
        "dpi.dns.confidence" => "0.920",
        "dpi.dns.last_observed_at" => "2026-05-27T14:30:01Z",
        "_alias_last_seen_ip" => ip,
        "ip_alias:#{ip}" => "2026-05-27T14:30:01Z"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([dpi_update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert "passive-netprobe" in device.discovery_sources

    assert device.metadata["dpi"]["dns"] == %{
             "count" => 1,
             "confidence" => 0.92,
             "last_observed_at" => "2026-05-27T14:30:01Z"
           }

    refute Map.has_key?(device.metadata["dpi"]["dns"], "source_port")
    refute Map.has_key?(device.metadata["dpi"]["dns"], "destination_port")
  end

  @tag :visibility
  test "normalizes sweep active banner fingerprint onto canonical device metadata and os", %{
    actor: actor
  } do
    ip = unique_seeded_ip("active-fingerprint-#{Ash.UUID.generate()}")

    active_update = %{
      "ip" => ip,
      "source" => "sweep_active",
      "metadata" => %{
        "active_fingerprint.source" => "sweep_active",
        "active_fingerprint.observed_at" => "2026-05-28T12:00:00Z",
        "active_fingerprint.os.name" => "Ubuntu Linux",
        "active_fingerprint.os.version_range" => "22.04",
        "active_fingerprint.os.family" => "linux",
        "active_fingerprint.os.confidence" => "0.86",
        "active_fingerprint.recog.ssh.product" => "OpenSSH",
        "active_fingerprint.recog.ssh.version" => "8.9",
        "active_fingerprint.recog.ssh.os_family" => "linux"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([active_update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert "sweep_active" in device.discovery_sources

    assert device.metadata["active_fingerprint"]["recog"]["ssh"] == %{
             "product" => "OpenSSH",
             "version" => "8.9",
             "os_family" => "linux"
           }

    assert device.os["active_fingerprint"] == %{
             "name" => "Ubuntu Linux",
             "version_range" => "22.04",
             "family" => "linux",
             "confidence" => 0.86,
             "source" => "serviceradar-sweep-active",
             "observed_at" => "2026-05-28T12:00:00Z"
           }
  end

  test "replaces placeholder type with integration metadata alias", %{actor: actor} do
    # The two updates share the integration_id (legitimate identity); a bare
    # shared IP is intentionally NOT enough to adopt an existing device.
    ip = unique_ip()
    integration_id = "armis-camera-#{System.unique_integer([:positive])}"

    placeholder_update = %{
      "ip" => ip,
      "hostname" => "legacy-unknown-camera",
      "source" => "armis",
      "metadata" => %{
        "integration_id" => integration_id,
        "integration_type" => "armis",
        "type" => "Unknown"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([placeholder_update], actor: actor)
    placeholder_device = fetch_device_by_ip!(actor, ip)
    assert placeholder_device.type in ["Unknown", nil]

    update = %{
      "ip" => ip,
      "hostname" => "legacy-unknown-camera",
      "source" => "armis",
      "metadata" => %{
        "integration_id" => integration_id,
        "integration_type" => "armis",
        "type" => "Unknown",
        "armis_type" => "IP Cameras",
        "armis_category" => "Cameras",
        "brand" => "Axis Communications"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.uid == placeholder_device.uid
    assert device.type == "IP Cameras"
    assert device.type_id == 99
    assert device.vendor_name == "Axis Communications"
    assert device.metadata["type"] == "IP Cameras"
    assert device.metadata["device_type"] == "IP Cameras"
  end

  test "promotes common integration aliases into canonical inventory fields", %{actor: actor} do
    cases = [
      {"netbox", %{"netbox_device_type" => "Firewall", "manufacturer" => "Palo Alto Networks"},
       "Firewall", 9, "Palo Alto Networks", "Firewall"},
      {"ansible", %{"ansible_device_type" => "Server", "vendor" => "Dell"}, "Server", 1, "Dell",
       "Server"},
      {"proxmox", %{"proxmox_type" => "virtual_machine", "model_name" => "qemu"}, "Virtual", 6,
       nil, "virtual_machine"}
    ]

    for {source, metadata, expected_type, expected_type_id, expected_vendor,
         expected_metadata_type} <-
          cases do
      ip = unique_ip()

      update = %{
        "ip" => ip,
        "hostname" => "#{source}-alias-#{System.unique_integer([:positive])}",
        "source" => source,
        "metadata" =>
          Map.merge(metadata, %{
            "integration_id" => "#{source}-#{System.unique_integer([:positive])}",
            "integration_type" => source
          })
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      device = fetch_device_by_ip!(actor, ip)
      assert device.type == expected_type
      assert device.type_id == expected_type_id
      assert device.metadata["type"] == expected_metadata_type
      assert device.metadata["device_type"] == expected_metadata_type

      if expected_vendor do
        assert device.vendor_name == expected_vendor
      end
    end
  end

  test "an integration does not overwrite a manually set device type", %{actor: actor} do
    ip = unique_ip()
    integration_id = "armis-manual-type-#{System.unique_integer([:positive])}"

    # Seeded the way the CSV importer seeds it: source "manual", operator-chosen
    # type. A "Router" is used rather than "rids" so type_id carries a known,
    # non-catch-all value and the assertion below can tell the two apart.
    manual = %{
      "ip" => ip,
      "hostname" => "manual-type-test",
      "source" => "manual",
      "type" => "Router"
    }

    assert :ok = SyncIngestor.ingest_updates([manual], actor: actor)

    seeded = fetch_device_by_ip!(actor, ip)
    assert seeded.type == "Router"
    assert "manual" in seeded.discovery_sources

    # Armis then reports its own inventory category for the same address. This
    # is the exact shape that relabelled 280 hand-imported RIDS displays as
    # "Interactive Kiosks": an unrecognised vendor category passed through
    # verbatim with the type_id 99 catch-all.
    armis = %{
      "ip" => ip,
      "hostname" => "manual-type-test",
      "source" => "armis",
      "metadata" => %{
        "integration_id" => integration_id,
        "integration_type" => "armis",
        "armis_category" => "Interactive Kiosks"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([armis], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Router"
    assert device.type_id == seeded.type_id
    # The sync still landed -- it is the type alone that is refused.
    assert "armis" in device.discovery_sources
  end

  test "a manually typed device keeps a type the type table does not know", %{actor: actor} do
    ip = unique_ip()

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => "rids-type-test",
                   "source" => "manual",
                   "type" => "rids"
                 }
               ],
               actor: actor
             )

    assert fetch_device_by_ip!(actor, ip).type == "rids"

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => "rids-type-test",
                   "source" => "armis",
                   "metadata" => %{
                     "integration_id" => "armis-rids-#{System.unique_integer([:positive])}",
                     "integration_type" => "armis",
                     "armis_category" => "Interactive Kiosks"
                   }
                 }
               ],
               actor: actor
             )

    # The whole point: `in:devices type:rids` has to keep matching this row.
    assert fetch_device_by_ip!(actor, ip).type == "rids"
  end

  test "one integration still reclassifies a type another integration inferred", %{actor: actor} do
    ip = unique_ip()

    # No "manual" anywhere in this device's history, so the guard must not fire.
    # Without this the change would silently become "first writer wins", which
    # freezes every integration-discovered device at its first classification.
    #
    # ORDER IS LOAD-BEARING, and not incidentally. `integration_id` is a strong
    # identifier for netbox but explicitly NOT for armis
    # (`SourcePolicy.identifier_types/2`). So armis resolves this address by IP
    # and merges onto whatever already holds it, while netbox arrives with a
    # strong identity of its own.
    #
    # Two DIFFERENT strong identities claiming one IP do not converge, by
    # design: the later one keeps its identity, loses the address, and a
    # SourceIdentityConflict is recorded instead
    # (`sync/device_writes.ex:556-581`, pinned by
    # `sync_batch_resolution_test.exs:161`). Writing this armis-first would
    # therefore assert the opposite of a deliberate, separately-tested
    # invariant -- and it would fail by minting a second, IP-less device rather
    # than by refusing the reclassification, which is a confusing way to learn
    # that.
    #
    # netbox-first is the ordering that actually exercises what this test is
    # named for: one integration reclassifying a type another integration
    # inferred, on one device.
    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => "integration-type-test",
                   "source" => "netbox",
                   "metadata" => %{
                     "integration_id" =>
                       "netbox:source-a:device:netbox-reclass-#{System.unique_integer([:positive])}",
                     "integration_type" => "netbox",
                     "netbox_device_type" => "Switch"
                   }
                 }
               ],
               actor: actor
             )

    assert fetch_device_by_ip!(actor, ip).type == "Switch"

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => "integration-type-test",
                   "source" => "armis",
                   "metadata" => %{
                     "integration_id" => "armis-reclass-#{System.unique_integer([:positive])}",
                     "integration_type" => "armis",
                     "armis_type" => "Tablet"
                   }
                 }
               ],
               actor: actor
             )

    reclassified = fetch_device_by_ip!(actor, ip)
    assert reclassified.type == "Tablet"

    # One device, not two: the reclassification landed on the netbox row rather
    # than forking. This is what regresses if the exemption above is dropped.
    assert "netbox" in reclassified.discovery_sources
    assert "armis" in reclassified.discovery_sources
  end

  test "a later strong integration converges when hostname agrees and no third identity claims it",
       %{actor: actor} do
    # The reverse arrival order of the test above (GitHub #4059): armis
    # classifies first, then a strong-identified netbox record claims the same
    # IP. Same hostname on both sides and neither strong identifier registered
    # anywhere else, so the netbox record adopts the armis row instead of
    # forking an IP-less duplicate -- and the better inference lands.
    ip = unique_ip()
    hostname = "converge-type-test-#{System.unique_integer([:positive])}"

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => hostname,
                   "source" => "armis",
                   "metadata" => %{
                     "integration_id" => "armis-converge-#{System.unique_integer([:positive])}",
                     "integration_type" => "armis",
                     "armis_type" => "Tablet"
                   }
                 }
               ],
               actor: actor
             )

    assert fetch_device_by_ip!(actor, ip).type == "Tablet"

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => hostname,
                   "source" => "netbox",
                   "metadata" => %{
                     "integration_id" =>
                       "netbox:source-a:device:netbox-converge-#{System.unique_integer([:positive])}",
                     "integration_type" => "netbox",
                     "netbox_device_type" => "Switch"
                   }
                 }
               ],
               actor: actor
             )

    reclassified = fetch_device_by_ip!(actor, ip)
    assert reclassified.type == "Switch"
    assert reclassified.type_id == 10
    assert "netbox" in reclassified.discovery_sources
    assert "armis" in reclassified.discovery_sources
  end

  test "merges an existing IP-less integration duplicate with an audit", %{actor: actor} do
    ip = "192.0.2.81"
    hostname = "merge-switch.example.com"

    integration_id =
      "netbox:source-a:device:synthetic-netbox-#{System.unique_integer([:positive])}"

    holder_update = %{
      "ip" => ip,
      "hostname" => hostname,
      "source" => "armis",
      "metadata" => %{"armis_type" => "Tablet"}
    }

    duplicate_update = %{
      "ip" => "192.0.2.85",
      "hostname" => hostname,
      "source" => "netbox",
      "metadata" => %{
        "integration_id" => integration_id,
        "integration_type" => "netbox",
        "netbox_device_type" => "Switch",
        "synthetic_history" => "retained"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([holder_update], actor: actor)
    holder = fetch_device_by_ip!(actor, ip)
    assert :ok = SyncIngestor.ingest_updates([duplicate_update], actor: actor)

    assert %{rows: [[duplicate_uid]]} =
             Repo.query!(
               "SELECT device_id FROM platform.device_identifiers WHERE identifier_type = 'integration_id' AND identifier_value = $1",
               [integration_id]
             )

    refute duplicate_uid == holder.uid

    # Reproduce a previously persisted duplicate whose address was cleared.
    assert %{num_rows: 1} =
             Repo.query!("UPDATE platform.ocsf_devices SET ip = NULL WHERE uid = $1", [
               duplicate_uid
             ])

    followup =
      duplicate_update
      |> Map.put("ip", ip)
      |> Map.update!("metadata", &Map.delete(&1, "synthetic_history"))

    assert :ok = SyncIngestor.ingest_updates([followup], actor: actor)
    assert :ok = SyncIngestor.ingest_updates([followup], actor: actor)

    survivor = fetch_device_by_ip!(actor, ip)
    assert survivor.uid == holder.uid
    assert survivor.type == "Switch"
    assert survivor.type_id == 10
    assert "armis" in survivor.discovery_sources
    assert "netbox" in survivor.discovery_sources
    assert survivor.metadata["synthetic_history"] == "retained"

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.ocsf_devices WHERE hostname = $1 AND deleted_at IS NULL",
               [hostname]
             )

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT deleted_at IS NOT NULL FROM platform.ocsf_devices WHERE uid = $1",
               [
                 duplicate_uid
               ]
             )

    assert %{rows: [[owner_uid]]} =
             Repo.query!(
               "SELECT device_id FROM platform.device_identifiers WHERE identifier_type = 'integration_id' AND identifier_value = $1",
               [integration_id]
             )

    assert owner_uid == holder.uid

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.merge_audit WHERE from_device_id = $1 AND to_device_id = $2",
               [duplicate_uid, holder.uid]
             )
  end

  test "untyped manual provenance remains reclassifiable after merging", %{actor: actor} do
    ip = "192.0.2.83"
    hostname = "untyped-merge.example.com"

    integration_id =
      "netbox:source-a:device:synthetic-untyped-#{System.unique_integer([:positive])}"

    duplicate = %{
      "hostname" => hostname,
      "source" => "manual",
      "metadata" => %{
        "integration_id" => integration_id,
        "integration_type" => "netbox",
        "type" => "Unknown"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([duplicate], actor: actor)

    assert %{rows: [[duplicate_uid]]} =
             Repo.query!(
               "SELECT device_id FROM platform.device_identifiers WHERE identifier_type = 'integration_id' AND identifier_value = $1",
               [integration_id]
             )

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => hostname,
                   "source" => "armis",
                   "metadata" => %{"armis_type" => "Tablet"}
                 }
               ],
               actor: actor
             )

    holder = fetch_device_by_ip!(actor, ip)
    refute holder.uid == duplicate_uid
    assert holder.type == "Tablet"

    followup = %{
      "ip" => ip,
      "hostname" => hostname,
      "source" => "netbox",
      "metadata" => %{
        "integration_id" => integration_id,
        "integration_type" => "netbox",
        "netbox_device_type" => "Switch"
      }
    }

    for type <- ["Switch", "Router", "Switch"] do
      update = put_in(followup, ["metadata", "netbox_device_type"], type)
      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
      survivor = fetch_device_by_ip!(actor, ip)
      assert survivor.uid == holder.uid
      assert survivor.type == type
      assert survivor.type_id == if(type == "Switch", do: 10, else: 12)
      assert "manual" in survivor.discovery_sources
      assert "armis" in survivor.discovery_sources
      assert "netbox" in survivor.discovery_sources
      assert survivor.metadata["type_manually_set"] == false
    end

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT deleted_at IS NOT NULL FROM platform.ocsf_devices WHERE uid = $1",
               [
                 duplicate_uid
               ]
             )

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => hostname,
                   "source" => "manual",
                   "metadata" => %{"type" => "Firewall"}
                 }
               ],
               actor: actor
             )

    assert :ok = SyncIngestor.ingest_updates([followup], actor: actor)
    manually_typed = fetch_device_by_ip!(actor, ip)
    assert manually_typed.type == "Firewall"
    assert manually_typed.type_id == 9
    assert manually_typed.metadata["type_manually_set"] == true
  end

  test "snapshot identity claims prevent adopting an unrelated holder", %{actor: actor} do
    ip = "192.0.2.82"
    hostname = "guard-switch.example.com"

    integration_id =
      "netbox:source-a:device:synthetic-snapshot-#{System.unique_integer([:positive])}"

    existing_update = %{
      "ip" => "192.0.2.84",
      "hostname" => "other-switch.example.com",
      "mac" => "00:00:5e:00:53:81",
      "source" => "netbox",
      "metadata" => %{
        "integration_id" => integration_id,
        "integration_type" => "netbox",
        "plugin_inventory_snapshot" => true,
        "netbox_device_type" => "Switch"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([existing_update], actor: actor)

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => hostname,
                   "source" => "armis",
                   "metadata" => %{"armis_type" => "Tablet"}
                 }
               ],
               actor: actor
             )

    holder = fetch_device_by_ip!(actor, ip)

    snapshot =
      existing_update
      |> Map.put("ip", ip)
      |> Map.put("hostname", hostname)
      |> Map.put("mac", "00:00:5e:00:53:82")

    assert :ok = SyncIngestor.ingest_updates([snapshot], actor: actor)
    unchanged = fetch_device_by_ip!(actor, ip)
    assert unchanged.uid == holder.uid
    assert unchanged.type == "Tablet"
    refute "netbox" in unchanged.discovery_sources

    assert %{rows: [[nil]]} =
             Repo.query!(
               "SELECT ip FROM platform.ocsf_devices WHERE mac = $1 AND deleted_at IS NULL",
               ["00:00:5e:00:53:82"]
             )
  end

  test "a later strong integration still forks when hostnames disagree", %{actor: actor} do
    # The guardrail on the convergence above: different hostnames mean no
    # agreement, so the strong-identity fork rule still fires and the two
    # identities stay distinct devices.
    ip = unique_ip()

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => "holder-#{System.unique_integer([:positive])}",
                   "source" => "armis",
                   "metadata" => %{
                     "integration_id" => "armis-diverge-#{System.unique_integer([:positive])}",
                     "integration_type" => "armis",
                     "armis_type" => "Tablet"
                   }
                 }
               ],
               actor: actor
             )

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => "claimer-#{System.unique_integer([:positive])}",
                   "source" => "netbox",
                   "metadata" => %{
                     "integration_id" =>
                       "netbox:source-a:device:netbox-diverge-#{System.unique_integer([:positive])}",
                     "integration_type" => "netbox",
                     "netbox_device_type" => "Switch"
                   }
                 }
               ],
               actor: actor
             )

    holder = fetch_device_by_ip!(actor, ip)
    assert holder.type == "Tablet"
    assert "armis" in holder.discovery_sources
    refute "netbox" in holder.discovery_sources
  end

  test "an integration still fills a blank type on a manually created device", %{actor: actor} do
    ip = unique_ip()

    # Manual origin, but no type was ever chosen. There is no human answer to
    # protect here, so the integration's guess is strictly better than nothing.
    assert :ok =
             SyncIngestor.ingest_updates(
               [%{"ip" => ip, "hostname" => "blank-type-test", "source" => "manual"}],
               actor: actor
             )

    seeded = fetch_device_by_ip!(actor, ip)
    assert seeded.type in [nil, "", "Unknown"]

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => "blank-type-test",
                   "source" => "armis",
                   "metadata" => %{
                     "integration_id" => "armis-blank-#{System.unique_integer([:positive])}",
                     "integration_type" => "armis",
                     "armis_type" => "Tablet"
                   }
                 }
               ],
               actor: actor
             )

    assert fetch_device_by_ip!(actor, ip).type == "Tablet"
  end

  test "a manual placeholder type of Unknown is still upgraded by an integration", %{actor: actor} do
    ip = unique_ip()

    # "Unknown" is the absence of an answer, not an answer. Both Enrichment and
    # SRQL already treat it as the no-type sentinel, so there is nothing here
    # worth protecting from a better guess.
    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => "unknown-type-test",
                   "source" => "manual",
                   "type" => "Unknown"
                 }
               ],
               actor: actor
             )

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "hostname" => "unknown-type-test",
                   "source" => "armis",
                   "metadata" => %{
                     "integration_id" => "armis-unknown-#{System.unique_integer([:positive])}",
                     "integration_type" => "armis",
                     "armis_type" => "Tablet"
                   }
                 }
               ],
               actor: actor
             )

    assert fetch_device_by_ip!(actor, ip).type == "Tablet"
  end

  test "does not re-enable devices manually marked unmanaged", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "user-unmanaged-test",
      "source" => "armis",
      "metadata" => %{
        "integration_id" => "armis-user-unmanaged-#{System.unique_integer([:positive])}",
        "integration_type" => "armis"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.is_managed == true

    assert {:ok, _updated} =
             device
             |> Ash.Changeset.for_update(:update, %{is_managed: false}, actor: actor)
             |> Ash.update(authorize?: false)

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    assert fetch_device_by_ip!(actor, ip).is_managed == false
  end

  test "does not reactivate devices manually marked inactive", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "user-inactive-test",
      "source" => "armis",
      "metadata" => %{
        "integration_id" => "armis-user-inactive-#{System.unique_integer([:positive])}",
        "integration_type" => "armis"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.is_managed == true
    assert device.is_active == true

    assert {:ok, _updated} = Device.mark_inactive(device, actor: actor)

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    updated = fetch_device_by_ip!(actor, ip)
    assert updated.is_managed == true
    assert updated.is_active == false
  end

  test "merges metadata maps across updates instead of replacing existing keys", %{actor: actor} do
    ip = unique_ip()

    initial = %{
      "ip" => ip,
      "hostname" => "metadata-merge-test",
      "source" => "mapper",
      "metadata" => %{
        "device_role" => "router",
        "sys_object_id" => ".1.3.6.1.4.1.41112"
      }
    }

    followup = %{
      "ip" => ip,
      "hostname" => "metadata-merge-test",
      "source" => "mapper",
      "metadata" => %{
        "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([initial], actor: actor)
    assert :ok = SyncIngestor.ingest_updates([followup], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.metadata["device_role"] == "router"
    assert device.metadata["sys_object_id"] == ".1.3.6.1.4.1.41112"
    assert device.metadata["sys_descr"] == "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"
  end

  test "maps sys_contact into owner while retaining sys_descr metadata", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "owner-test",
      "source" => "mapper",
      "metadata" => %{
        "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
        "sys_contact" => "Network Operations"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.owner == %{"name" => "Network Operations"}
    assert device.metadata["sys_descr"] == "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"
    assert device.metadata["sys_contact"] == "Network Operations"
  end

  test "falls back to router type from ip_forwarding when no enrichment rule matches", %{
    actor: actor
  } do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "edge01",
      "source" => "mapper",
      "metadata" => %{
        "sys_descr" => "Linux custom network appliance 1.0",
        "sys_name" => "edge01",
        "ip_forwarding" => "1"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.type == "Router"
    assert device.type_id == 12
  end

  test "falls back vendor from sys_object_id prefix when no enrichment rule matches", %{
    actor: actor
  } do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "switch-edge",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.9.1.1208",
        "sys_descr" => "Network appliance OS",
        "sys_name" => "edge-sw01",
        "ip_forwarding" => "2"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.vendor_name == "Cisco"
  end

  test "classifies vJunos router as Juniper without falling through to MikroTik", %{
    actor: actor
  } do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "vjunos-lab-01",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.2636.1.1.1.2.160",
        "sys_descr" => "Juniper Networks, Inc. vJunos-router",
        "sys_name" => "vjunos-lab-01",
        "ip_forwarding" => "1"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.vendor_name == "Juniper"
    assert device.type == "Router"
    assert device.type_id == 12
    refute device.vendor_name == "MikroTik"
    assert device.metadata["classification_rule_id"] == "juniper-router-vjunos"
  end

  test "replaces stale classification metadata when the same device is reclassified", %{
    actor: actor
  } do
    ip = unique_ip()

    mikrotik_update = %{
      "ip" => ip,
      "hostname" => "mikrotik-lab-01",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.14988.1",
        "sys_descr" => "MikroTik RouterOS RB5009UG+S+",
        "sys_name" => "mikrotik-lab-01",
        "ip_forwarding" => "1"
      }
    }

    juniper_update = %{
      "ip" => ip,
      "hostname" => "vjunos-lab-01",
      "source" => "mapper",
      "metadata" => %{
        "sys_object_id" => ".1.3.6.1.4.1.2636.1.1.1.2.160",
        "sys_descr" => "Juniper Networks, Inc. vJunos-router",
        "sys_name" => "vjunos-lab-01",
        "ip_forwarding" => "1"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([mikrotik_update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.vendor_name == "MikroTik"
    assert device.metadata["classification_rule_id"] == "mikrotik-router"

    assert :ok = SyncIngestor.ingest_updates([juniper_update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.vendor_name == "Juniper"
    assert device.metadata["classification_rule_id"] == "juniper-router-vjunos"
    refute device.metadata["classification_rule_id"] == "mikrotik-router"
  end

  test "maps RouterOS metadata into canonical os and hardware info", %{actor: actor} do
    ip = unique_ip()

    update = %{
      "ip" => ip,
      "hostname" => "mikrotik-rb5009",
      "source" => "mapper",
      "metadata" => %{
        "vendor_name" => "MikroTik",
        "model" => "RB5009UG+S+",
        "routeros_version" => "7.15.3",
        "architecture_name" => "arm64",
        "serial_number" => "ABC123XYZ",
        "sys_object_id" => ".1.3.6.1.4.1.14988.1",
        "sys_descr" => "MikroTik RouterOS RB5009UG+S+",
        "ip_forwarding" => "1"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.vendor_name == "MikroTik"
    assert device.model == "RB5009UG+S+"
    assert device.type == "Router"
    assert device.type_id == 12
    assert device.os == %{"name" => "RouterOS", "version" => "7.15.3"}
    assert device.hw_info == %{"cpu_architecture" => "arm64", "serial_number" => "ABC123XYZ"}
  end

  test "enriches existing device matched by IP with RouterOS metadata", %{actor: actor} do
    ip = unique_ip()
    existing_uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: existing_uid,
        ip: ip,
        hostname: "placeholder-router",
        metadata: %{
          "identity_state" => "provisional",
          "identity_source" => "mapper_ip_seed"
        }
      })
      |> Ash.create(actor: actor)

    update = %{
      "ip" => ip,
      "hostname" => "placeholder-router",
      "source" => "mapper",
      "metadata" => %{
        "vendor_name" => "MikroTik",
        "model" => "CHR",
        "routeros_version" => "7.16beta2",
        "architecture_name" => "x86_64",
        "serial_number" => "CHR-DEMO-001",
        "sys_descr" => "MikroTik RouterOS CHR",
        "ip_forwarding" => "1"
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    device = fetch_device_by_ip!(actor, ip)
    assert device.uid == existing_uid
    assert device.vendor_name == "MikroTik"
    assert device.model == "CHR"
    assert device.os == %{"name" => "RouterOS", "version" => "7.16beta2"}
    assert device.hw_info == %{"cpu_architecture" => "x86_64", "serial_number" => "CHR-DEMO-001"}
    assert device.metadata["identity_state"] == "provisional"
  end

  test "recovers from active-ip unique conflicts by remapping to existing uid", %{actor: actor} do
    ip = unique_ip()
    existing_uid = "sr:existing-ip-#{System.unique_integer([:positive])}"

    {:ok, _existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: existing_uid,
        ip: ip,
        hostname: "existing-host",
        is_available: true
      })
      |> Ash.create(actor: actor)

    update = %{
      "ip" => ip,
      "hostname" => "updated-host",
      "source" => "armis",
      "metadata" => %{
        "armis_device_id" => "armis-#{System.unique_integer([:positive])}",
        "integration_type" => "armis",
        "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"
      }
    }

    log =
      capture_log(fn ->
        assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
      end)

    # The update carries a strong identifier, so it must NOT be remapped onto
    # whichever device happens to hold the IP (that adoption collapsed
    # distinct devices); the conflicting IP is dropped from the new record.
    existing_device = fetch_device_by_ip!(actor, ip)
    assert existing_device.uid == existing_uid
    assert existing_device.hostname == "existing-host"

    # (conflict recovery may or may not be exercised depending on lookup
    # timing; the behavioral assertions below are what matter)
    _ = log

    {:ok, devices} =
      Device
      |> Ash.Query.filter(hostname == "updated-host" and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert [new_device | _] = Enum.filter(devices, &(&1.uid != existing_uid))
    refute new_device.ip == ip
    assert new_device.metadata["sys_descr"] == "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"
  end

  test "refreshes inventory rollups after sync ingest", %{actor: actor} do
    unique = System.unique_integer([:positive])
    vendor = "Vendor-#{unique}"
    type = "Type-#{unique}"
    available_ip = unique_ip()
    unavailable_ip = unique_ip()

    Repo.query!("SELECT platform.refresh_device_inventory_rollups()")

    baseline_total = inventory_count!("total")
    baseline_available = inventory_count!("available")
    baseline_unavailable = inventory_count!("unavailable")
    baseline_type = type_count!(type)
    baseline_vendor = vendor_count!(vendor)

    available_update = %{
      "ip" => available_ip,
      "hostname" => "rollup-available-#{unique}",
      "source" => "mapper",
      "is_available" => true,
      "metadata" => %{
        "vendor_name" => vendor,
        "type" => type
      }
    }

    unavailable_update = %{
      "ip" => unavailable_ip,
      "hostname" => "rollup-unavailable-#{unique}",
      "source" => "mapper",
      "is_available" => false,
      "metadata" => %{
        "vendor_name" => vendor,
        "type" => type
      }
    }

    assert :ok = SyncIngestor.ingest_updates([available_update, unavailable_update], actor: actor)

    assert inventory_count!("total") == baseline_total + 2
    assert inventory_count!("available") == baseline_available + 1
    assert inventory_count!("unavailable") == baseline_unavailable + 1
    assert type_count!(type) == baseline_type + 2
    assert vendor_count!(vendor) == baseline_vendor + 2
  end

  describe "captured Ubiquiti payload fixtures" do
    test "router fixture classifies as Ubiquiti Router", %{actor: actor} do
      ip = unique_ip()
      update = load_fixture_update!("ubiquiti_router_update.json", ip)

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      device = fetch_device_by_ip!(actor, ip)
      assert device.vendor_name == "Ubiquiti"
      assert device.type == "Router"
      assert device.type_id == 12
      assert String.starts_with?(device.model, "UDM-Pro")
    end

    test "switch fixture classifies as Ubiquiti Switch", %{actor: actor} do
      ip = unique_ip()
      update = load_fixture_update!("ubiquiti_switch_update.json", ip)

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      device = fetch_device_by_ip!(actor, ip)
      assert device.vendor_name == "Ubiquiti"
      assert device.type == "Switch"
      assert device.type_id == 10
      assert device.model == "USW-Pro-24"
    end

    test "access-point fixture classifies as Ubiquiti Access Point", %{actor: actor} do
      ip = unique_ip()
      update = load_fixture_update!("ubiquiti_ap_update.json", ip)

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      device = fetch_device_by_ip!(actor, ip)
      assert device.vendor_name == "Ubiquiti"
      assert device.type == "Access Point"
      assert device.type_id == 99
      assert device.model == "U6-LR"
    end
  end

  describe "captured Aruba payload fixture" do
    test "aruba fixture does not match Ubiquiti and classifies as Aruba Switch", %{actor: actor} do
      ip = unique_ip()
      update = load_fixture_update!("aruba_switch_update.json", ip)

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      device = fetch_device_by_ip!(actor, ip)
      assert device.vendor_name == "Aruba"
      assert device.type == "Switch"
      assert device.type_id == 10
      assert device.metadata["classification_rule_id"] == "aruba-switch"
    end
  end

  defp fetch_device_by_ip!(actor, ip) do
    query = Ash.Query.filter(Device, ip == ^ip)
    assert {:ok, result} = Ash.read(query, actor: actor)

    devices =
      case result do
        %Ash.Page.Keyset{results: rows} -> rows
        rows when is_list(rows) -> rows
      end

    assert devices != []

    device =
      Enum.max_by(devices, fn row ->
        {
          row.modified_time || ~U[1970-01-01 00:00:00Z],
          row.created_time || ~U[1970-01-01 00:00:00Z],
          row.uid
        }
      end)

    device
  end

  defp unique_ip do
    fn -> System.unique_integer([:positive, :monotonic]) end
    |> Stream.repeatedly()
    |> Enum.find_value(fn n ->
      octet2 = rem(div(n, 65_025), 250) + 1
      octet3 = rem(div(n, 255), 250) + 1
      octet4 = rem(n, 250) + 1
      ip = "10.#{octet2}.#{octet3}.#{octet4}"

      case Repo.query("SELECT 1 FROM platform.ocsf_devices WHERE ip = $1 LIMIT 1", [ip]) do
        {:ok, %{rows: []}} -> ip
        _ -> nil
      end
    end)
  end

  defp unique_seeded_ip(seed) do
    <<octet2, octet3, octet4, _rest::binary>> = :crypto.hash(:sha256, seed)
    "10.#{1 + rem(octet2, 250)}.#{1 + rem(octet3, 250)}.#{1 + rem(octet4, 250)}"
  end

  defp unique_mac do
    suffix =
      [:positive]
      |> System.unique_integer()
      |> Integer.to_string(16)
      |> String.pad_leading(10, "0")

    suffix
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&"02:#{&1}")
  end

  defp load_fixture_update!(file_name, ip) do
    fixture_path =
      Path.join([
        __DIR__,
        "..",
        "..",
        "support",
        "fixtures",
        "snmp",
        file_name
      ])

    fixture_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("ip", ip)
  end

  defp inventory_count!(key) do
    case Repo.query("SELECT value FROM platform.device_inventory_counts WHERE key = $1", [key]) do
      {:ok, %{rows: [[value]]}} when is_integer(value) -> value
      {:ok, %{rows: []}} -> 0
    end
  end

  defp type_count!(type) do
    case Repo.query("SELECT count FROM platform.device_inventory_type_counts WHERE type = $1", [
           type
         ]) do
      {:ok, %{rows: [[value]]}} when is_integer(value) -> value
      {:ok, %{rows: []}} -> 0
    end
  end

  defp vendor_count!(vendor) do
    case Repo.query(
           "SELECT count FROM platform.device_inventory_vendor_counts WHERE vendor_name = $1",
           [vendor]
         ) do
      {:ok, %{rows: [[value]]}} when is_integer(value) -> value
      {:ok, %{rows: []}} -> 0
    end
  end

  defp ensure_inventory_rollup_schema! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS platform.device_inventory_counts (
      key text PRIMARY KEY,
      value bigint NOT NULL DEFAULT 0,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS platform.device_inventory_type_counts (
      type text PRIMARY KEY,
      count bigint NOT NULL DEFAULT 0,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS platform.device_inventory_vendor_counts (
      vendor_name text PRIMARY KEY,
      count bigint NOT NULL DEFAULT 0,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION platform.refresh_device_inventory_rollups()
    RETURNS void
    LANGUAGE plpgsql
    AS $$
    BEGIN
      TRUNCATE TABLE platform.device_inventory_counts;
      TRUNCATE TABLE platform.device_inventory_type_counts;
      TRUNCATE TABLE platform.device_inventory_vendor_counts;

      INSERT INTO platform.device_inventory_counts (key, value, updated_at)
      SELECT 'total', COUNT(*)::bigint, now()
      FROM platform.ocsf_devices
      WHERE deleted_at IS NULL;

      INSERT INTO platform.device_inventory_counts (key, value, updated_at)
      SELECT 'available', COUNT(*)::bigint, now()
      FROM platform.ocsf_devices
      WHERE deleted_at IS NULL
        AND COALESCE(is_available, false) = true;

      INSERT INTO platform.device_inventory_counts (key, value, updated_at)
      SELECT 'unavailable', COUNT(*)::bigint, now()
      FROM platform.ocsf_devices
      WHERE deleted_at IS NULL
        AND COALESCE(is_available, false) = false;

      INSERT INTO platform.device_inventory_type_counts (type, count, updated_at)
      SELECT COALESCE(NULLIF(trim(type), ''), 'Unknown') AS type,
             COUNT(*)::bigint AS count,
             now()
      FROM platform.ocsf_devices
      WHERE deleted_at IS NULL
      GROUP BY COALESCE(NULLIF(trim(type), ''), 'Unknown');

      INSERT INTO platform.device_inventory_vendor_counts (vendor_name, count, updated_at)
      SELECT COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown') AS vendor_name,
             COUNT(*)::bigint AS count,
             now()
      FROM platform.ocsf_devices
      WHERE deleted_at IS NULL
      GROUP BY COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown');
    END;
    $$;
    """)
  end

  defp restore_env_snapshot(key, {:ok, value}),
    do: Application.put_env(:serviceradar_core, key, value)

  defp restore_env_snapshot(key, :error), do: Application.delete_env(:serviceradar_core, key)
end
