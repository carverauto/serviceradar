defmodule ServiceRadar.Inventory.SyncBatchResolutionTest do
  @moduledoc """
  Integration coverage for batch identity resolution (tasks 2.4/5.1):

  - IP fallback never overrides strong identifiers (no adoption of an
    existing device just because it holds the update's IP)
  - distinct strong-identified updates in one batch stay distinct
    (regression for the 500-per-batch integration_id collapse)
  - active-IP-conflict recovery drops the conflicting IP from
    strong-identified records instead of remapping them onto the holder
  - pre-set merged-away sr: IDs resolve to the canonical survivor
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_batch_resolution_test)
    {:ok, actor: actor}
  end

  defp unique_ip do
    a = System.unique_integer([:positive])
    "10.#{rem(div(a, 65_536), 60) + 60}.#{rem(div(a, 256), 256)}.#{rem(a, 254) + 1}"
  end

  defp integration_update(integration_id, ip, hostname) do
    %{
      "ip" => ip,
      "hostname" => hostname,
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => integration_id
      }
    }
  end

  defp device_for_integration_id(integration_id, actor) do
    query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :integration_id,
        identifier_value: integration_id,
        partition: "default"
      })

    case Ash.read(query, actor: actor) do
      {:ok, [identifier | _]} -> identifier.device_id
      _ -> nil
    end
  end

  test "strong-identified update does not adopt an existing device by IP", %{actor: actor} do
    ip = unique_ip()

    {:ok, existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "ip-holder-#{System.unique_integer([:positive])}",
        ip: ip
      })
      |> Ash.create(actor: actor)

    integration_id = "it-#{System.unique_integer([:positive])}"
    update = integration_update(integration_id, ip, "strong-newcomer")

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    resolved = device_for_integration_id(integration_id, actor)
    assert is_binary(resolved)
    assert resolved != existing.uid
  end

  test "weak update still adopts an existing device by IP", %{actor: actor} do
    ip = unique_ip()

    {:ok, existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "weak-ip-holder-#{System.unique_integer([:positive])}",
        ip: ip
      })
      |> Ash.create(actor: actor)

    update = %{
      "ip" => ip,
      "hostname" => "weak-sighting",
      "source" => "sweep"
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    {:ok, devices} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> ServiceRadar.Ash.Page.unwrap()

    assert [%Device{uid: uid}] = devices
    assert uid == existing.uid
  end

  test "distinct strong-identified updates in one batch stay distinct devices", %{actor: actor} do
    count = 20

    updates =
      for n <- 1..count do
        integration_update(
          "batch-it-#{System.unique_integer([:positive])}-#{n}",
          unique_ip(),
          "batch-host-#{n}"
        )
      end

    assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)

    device_ids =
      Enum.map(updates, fn u ->
        device_for_integration_id(u["metadata"]["integration_id"], actor)
      end)

    assert Enum.all?(device_ids, &is_binary/1)
    assert length(Enum.uniq(device_ids)) == count
  end

  test "IP conflict drops IP from strong-identified record instead of remapping", %{actor: actor} do
    ip = unique_ip()
    integration_a = "conflict-a-#{System.unique_integer([:positive])}"
    integration_b = "conflict-b-#{System.unique_integer([:positive])}"

    # First strong device claims the IP.
    assert :ok =
             SyncIngestor.ingest_updates([integration_update(integration_a, ip, "holder-a")],
               actor: actor
             )

    # Second strong device arrives claiming the SAME IP in a later batch.
    assert :ok =
             SyncIngestor.ingest_updates([integration_update(integration_b, ip, "claimer-b")],
               actor: actor
             )

    device_a = device_for_integration_id(integration_a, actor)
    device_b = device_for_integration_id(integration_b, actor)

    assert is_binary(device_a)
    assert is_binary(device_b)
    assert device_a != device_b

    {:ok, %Device{deleted_at: nil}} = Device.get_by_uid(device_a, false, actor: actor)
    {:ok, device_b_row} = Device.get_by_uid(device_b, false, actor: actor)
    refute device_b_row.ip == ip
  end

  test "pre-set merged-away sr: ID resolves to canonical survivor", %{actor: actor} do
    {:ok, from_device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "batch-follow-from-#{System.unique_integer([:positive])}",
        ip: nil
      })
      |> Ash.create(actor: actor)

    {:ok, to_device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "batch-follow-to-#{System.unique_integer([:positive])}",
        ip: nil
      })
      |> Ash.create(actor: actor)

    assert :ok =
             IdentityReconciler.merge_devices(from_device.uid, to_device.uid,
               actor: actor,
               reason: "manual_merge"
             )

    integration_id = "follow-it-#{System.unique_integer([:positive])}"

    update = %{
      "device_id" => from_device.uid,
      "ip" => unique_ip(),
      "hostname" => "batch-follow-update",
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => integration_id
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    # The identifier must land on the survivor, not resurrect the tombstone.
    assert device_for_integration_id(integration_id, actor) == to_device.uid
  end
end
