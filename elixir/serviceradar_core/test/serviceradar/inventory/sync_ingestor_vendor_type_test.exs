defmodule ServiceRadar.Inventory.SyncIngestorVendorTypeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceEnrichmentRules
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo

  require Ash.Query

  setup_all do
    test_rules_dir = Path.join(System.tmp_dir!(), "serviceradar-device-rules-empty")
    File.mkdir_p!(test_rules_dir)
    Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, test_rules_dir)
    DeviceEnrichmentRules.reload()
    ServiceRadar.TestSupport.start_core!()
    ensure_inventory_rollup_schema!()
    :ok
  end

  setup do
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
      "armis_device_id" => "armis-#{System.unique_integer([:positive])}",
      "metadata" => %{
        "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"
      }
    }

    log =
      capture_log(fn ->
        assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
      end)

    device = fetch_device_by_ip!(actor, ip)
    assert device.uid == existing_uid
    assert device.hostname == "updated-host"
    assert device.metadata["sys_descr"] == "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"
    refute log =~ "Bulk device upsert hit active-IP conflict"
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
end
