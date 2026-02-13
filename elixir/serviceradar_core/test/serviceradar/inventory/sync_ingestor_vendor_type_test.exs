defmodule ServiceRadar.Inventory.SyncIngestorVendorTypeTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, SyncIngestor}

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_vendor_type_test)
    {:ok, actor: actor}
  end

  test "infers Ubiquiti vendor from sys_object_id", %{actor: actor} do
    ip = "10.22.10.#{unique_octet()}"

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

    assert {:ok, [device]} = Device |> Ash.Query.filter(ip == ^ip) |> Ash.read(actor: actor)
    assert device.vendor_name == "Ubiquiti"
  end

  test "infers Ubiquiti vendor from UBNT sysDescr token", %{actor: actor} do
    ip = "10.22.11.#{unique_octet()}"

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

    assert {:ok, [device]} = Device |> Ash.Query.filter(ip == ^ip) |> Ash.read(actor: actor)
    assert device.vendor_name == "Ubiquiti"
  end

  test "infers router type from UDM sysDescr", %{actor: actor} do
    ip = "10.22.12.#{unique_octet()}"

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

    assert {:ok, [device]} = Device |> Ash.Query.filter(ip == ^ip) |> Ash.read(actor: actor)
    assert device.type == "Router"
    assert device.type_id == 12
  end

  test "infers switch type from USW sysDescr", %{actor: actor} do
    ip = "10.22.13.#{unique_octet()}"

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

    assert {:ok, [device]} = Device |> Ash.Query.filter(ip == ^ip) |> Ash.read(actor: actor)
    assert device.type == "Switch"
    assert device.type_id == 10
  end

  test "infers switch type from sys_name and ip_forwarding when sysDescr is generic", %{
    actor: actor
  } do
    ip = "10.22.16.#{unique_octet()}"

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

    assert {:ok, [device]} = Device |> Ash.Query.filter(ip == ^ip) |> Ash.read(actor: actor)
    assert device.type == "Switch"
    assert device.type_id == 10
  end

  test "infers router type from sys_name plus forwarding", %{actor: actor} do
    ip = "10.22.17.#{unique_octet()}"

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

    assert {:ok, [device]} = Device |> Ash.Query.filter(ip == ^ip) |> Ash.read(actor: actor)
    assert device.type == "Router"
    assert device.type_id == 12
  end

  test "infers access point type from U6 sysDescr", %{actor: actor} do
    ip = "10.22.14.#{unique_octet()}"

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

    assert {:ok, [device]} = Device |> Ash.Query.filter(ip == ^ip) |> Ash.read(actor: actor)
    assert device.type == "Access Point"
    assert device.type_id == 99
  end

  test "merges metadata maps across updates instead of replacing existing keys", %{actor: actor} do
    ip = "10.22.15.#{unique_octet()}"

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

    assert {:ok, [device]} = Device |> Ash.Query.filter(ip == ^ip) |> Ash.read(actor: actor)
    assert device.metadata["device_role"] == "router"
    assert device.metadata["sys_object_id"] == ".1.3.6.1.4.1.41112"
    assert device.metadata["sys_descr"] == "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324"
  end

  defp unique_octet do
    rem(System.unique_integer([:positive]), 200) + 10
  end
end
