defmodule ServiceRadar.Inventory.Identity.HardwareSerialBackfillTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.HardwareSerialBackfill

  test "plans only unique normalized serials and reports invalid and duplicate evidence" do
    devices = [
      device("sr:one", "Cisco Systems", "FOC1234ABC"),
      device("sr:duplicate-a", "Aruba", "CN12345678"),
      device("sr:duplicate-b", "HPE", "CN-12345678"),
      device("sr:invalid", "Unknown Vendor", "SER123")
    ]

    assert {:ok, plan} =
             HardwareSerialBackfill.plan(devices,
               existing_loader: fn keys ->
                 assert Enum.sort(keys) ==
                          Enum.sort([
                            {"default", "cisco:FOC1234ABC"}
                          ])

                 {:ok, %{}}
               end
             )

    assert plan.summary == %{
             total: 4,
             ready: 1,
             registered: 0,
             already_registered: 0,
             conflicts: 2,
             skipped: 1,
             errors: 0
           }

    assert [%{device_uid: "sr:one", identifier_value: "cisco:FOC1234ABC"}] =
             Enum.filter(plan.entries, &(&1.status == :ready))

    assert Enum.all?(
             Enum.filter(plan.entries, &(&1.status == :conflict)),
             &(&1.reason == :duplicate_serial_in_batch)
           )

    assert [%{reason: :invalid_or_unscoped_serial}] =
             Enum.filter(plan.entries, &(&1.status == :skipped))
  end

  test "existing ownership is idempotent for the same device and a conflict for another" do
    devices = [
      device("sr:same", "Cisco", "FOC1111AAA"),
      device("sr:other", "Cisco", "FOC2222BBB")
    ]

    assert {:ok, plan} =
             HardwareSerialBackfill.plan(devices,
               existing_loader: fn _keys ->
                 {:ok,
                  %{
                    {"default", "cisco:FOC1111AAA"} => "sr:same",
                    {"default", "cisco:FOC2222BBB"} => "sr:existing-owner"
                  }}
               end
             )

    assert Enum.find(plan.entries, &(&1.device_uid == "sr:same")).status == :already_registered

    conflict = Enum.find(plan.entries, &(&1.device_uid == "sr:other"))
    assert conflict.status == :conflict
    assert conflict.existing_owner_uid == "sr:existing-owner"
  end

  test "execute registers only ready rows and keeps a bounded audit projection" do
    parent = self()

    assert {:ok, plan} =
             HardwareSerialBackfill.plan(
               [device("sr:one", "Cisco", "FOC1234ABC")],
               existing_loader: fn _keys -> {:ok, %{}} end
             )

    assert {:ok, report} =
             HardwareSerialBackfill.execute(plan,
               actor: :system,
               registrar: fn entry, actor ->
                 send(parent, {:register, entry, actor})
                 :ok
               end
             )

    assert_receive {:register, entry, :system}

    assert entry.prior_evidence == %{
             "discovery_sources" => ["armis"],
             "serial_number" => "FOC1234ABC",
             "vendor_name" => "Cisco"
           }

    assert report.summary.registered == 1
    assert [%{status: :registered}] = report.entries
  end

  test "devices attached to multiple identifier partitions are skipped" do
    ambiguous =
      "sr:ambiguous"
      |> device("Cisco", "FOC1234ABC")
      |> Map.put(:partitions, ["default", "tenant-b"])

    assert {:ok, plan} =
             HardwareSerialBackfill.plan([ambiguous],
               existing_loader: fn [] -> {:ok, %{}} end
             )

    assert [%{status: :skipped, reason: :ambiguous_device_partition}] = plan.entries
  end

  defp device(uid, vendor, serial) do
    %{
      uid: uid,
      vendor_name: vendor,
      metadata: %{"serial_number" => serial},
      hw_info: %{},
      discovery_sources: ["armis"],
      partitions: ["default"]
    }
  end
end
