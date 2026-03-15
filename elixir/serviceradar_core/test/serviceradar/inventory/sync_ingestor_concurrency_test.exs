defmodule ServiceRadar.Inventory.SyncIngestorConcurrencyTest do
  @moduledoc """
  Integration coverage for concurrent sync ingestor upserts.

  In schema-agnostic mode, the DB schema is set by CNPG search_path credentials.
  Tests use TestSupport for schema isolation.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:sync_ingestor_test)

    {:ok, actor: actor}
  end

  test "concurrent batches upsert without duplicate key errors", %{
    actor: actor
  } do
    armis_id = "armis-#{System.unique_integer([:positive])}"
    ip_octet = rem(System.unique_integer([:positive]), 200) + 10
    ip = "10.0.1.#{ip_octet}"
    mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"

    update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "edge-#{ip_octet}",
      "metadata" => %{"armis_device_id" => armis_id}
    }

    identity_update = %{
      device_id: nil,
      ip: ip,
      mac: mac,
      hostname: "edge-#{ip_octet}",
      partition: "default",
      metadata: %{"armis_device_id" => armis_id}
    }

    assert {:ok, expected_id} =
             IdentityReconciler.resolve_device_id(identity_update, actor: actor)

    tasks =
      Enum.map(1..2, fn _ ->
        Task.async(fn ->
          SyncIngestor.ingest_updates([update], actor: actor)
        end)
      end)

    results = Task.await_many(tasks, 5_000)
    assert Enum.all?(results, &(&1 == :ok))

    # DB connection's search_path determines the schema
    assert {:ok, device} =
             Device.get_by_uid(expected_id, false, actor: actor)

    assert device.uid == expected_id

    identifier_query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :armis_device_id,
        identifier_value: armis_id,
        partition: "default"
      })

    assert {:ok, [identifier | _]} =
             Ash.read(identifier_query, actor: actor)

    assert identifier.device_id == expected_id
  end

  defp mac_suffix do
    [:positive]
    |> System.unique_integer()
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
