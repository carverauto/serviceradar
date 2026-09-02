defmodule ServiceRadar.Inventory.Sync.InterfacesUpsertFieldsTest do
  @moduledoc """
  The sync writer may only overwrite fields it actually sets.

  A field listed here that the builder does not set writes NULL over
  whatever the mapper wrote, on every poll, because `:unique_interface` is
  current-state `(device_id, interface_uid)`.

  This writer does not populate `if_index`, `if_speed`, `speed_bps`,
  `if_admin_status`, `if_oper_status`, `if_type`, `mtu`, `duplex` or
  `available_metrics`. Copying the mapper's list here would blank all nine on
  every sync run -- silently, and only after the rekey.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.Interfaces

  @identity_columns [:device_id, :interface_uid]

  # Fields the mapper sets and this writer does not. Listed explicitly so the
  # test states the hazard rather than merely computing around it.
  @mapper_only [
    :if_index,
    :if_speed,
    :speed_bps,
    :if_admin_status,
    :if_oper_status,
    :if_type,
    :mtu,
    :duplex,
    :available_metrics
  ]

  defp sample_record do
    update = %{
      agent_id: "agent-1",
      gateway_id: "gw-1",
      partition: "default",
      ip: "10.0.0.5",
      network_interfaces: [
        %{
          "name" => "eth0",
          "description" => "uplink",
          "alias" => "wan",
          "mac_address" => "F4:92:BF:75:C7:21",
          "type" => "ethernetCsmacd",
          "ip_addresses" => ["10.0.0.5"]
        }
      ]
    }

    [record] =
      Interfaces.build_interface_upsert_records(
        [{update, "sr:device-under-test"}],
        DateTime.utc_now()
      )

    record
  end

  test "every upsert field is one the builder actually sets" do
    record = sample_record()
    set_fields = record |> Map.keys() |> MapSet.new()

    missing = Enum.reject(Interfaces.upsert_fields(), &MapSet.member?(set_fields, &1))

    assert missing == [],
           "upsert_fields lists #{inspect(missing)}, which build_interface_record/5 never sets. " <>
             "On conflict those would be written as NULL over the mapper's values."
  end

  test "the identity columns are never overwritten" do
    overlap = Enum.filter(Interfaces.upsert_fields(), &(&1 in @identity_columns))

    assert overlap == [],
           "upsert_fields must not contain identity columns #{inspect(overlap)}"
  end

  test "created_at is not overwritten" do
    refute :created_at in Interfaces.upsert_fields(),
           "created_at is the first observation, not the latest"
  end

  test "the mapper-only operational fields are excluded" do
    leaked = Enum.filter(Interfaces.upsert_fields(), &(&1 in @mapper_only))

    assert leaked == [],
           "upsert_fields leaked mapper-only fields #{inspect(leaked)}; sync would blank them"
  end
end
