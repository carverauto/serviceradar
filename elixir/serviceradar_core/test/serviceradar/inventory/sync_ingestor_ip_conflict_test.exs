defmodule ServiceRadar.Inventory.SyncIngestorIpConflictTest do
  @moduledoc """
  Regression coverage for the active-IP unique-index conflict recovery path
  in `SyncIngestor.bulk_upsert_devices/1`.

  Source-authoritative integration identifiers must not be rebound to whichever
  unrelated device currently owns an IP. The conflict retry should preserve the
  source identity and drop the contested IP from the incoming strong device.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_ip_conflict_test)
    {:ok, actor: actor}
  end

  test "preserves generic integration identity when active-IP conflict triggers retry", %{
    actor: actor
  } do
    ip = unique_test_ip()
    integration_id = "integration-#{System.unique_integer([:positive])}"

    {:ok, existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "preexisting",
        ip: ip
      })
      |> Ash.create(actor: actor)

    update = %{
      "ip" => ip,
      "hostname" => "incoming",
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => integration_id
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert length(devices_at_ip) == 1
    [%Device{uid: canonical_uid}] = devices_at_ip
    assert canonical_uid == existing.uid

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value == ^integration_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{device_id: integration_device_uid}] = List.wrap(identifiers)
    assert integration_device_uid != canonical_uid

    {:ok, integration_device} = Device.get_by_uid(integration_device_uid, false, actor: actor)
    assert integration_device.ip == nil
  end

  test "retries a batch with colliding strong identities without choosing an IP owner", %{
    actor: actor
  } do
    ip = unique_test_ip()
    first_id = "integration-first-#{System.unique_integer([:positive])}"
    second_id = "integration-second-#{System.unique_integer([:positive])}"

    updates = [
      %{
        "ip" => ip,
        "hostname" => "first-incoming",
        "source" => "integration-test",
        "metadata" => %{
          "integration_type" => "test-integration",
          "integration_id" => first_id
        }
      },
      %{
        "ip" => ip,
        "hostname" => "second-incoming",
        "source" => "integration-test",
        "metadata" => %{
          "integration_type" => "test-integration",
          "integration_id" => second_id
        }
      }
    ]

    assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value in ^[first_id, second_id]
      )
      |> Ash.read(actor: actor)

    assert identifiers |> Enum.map(& &1.device_id) |> Enum.uniq() |> length() == 2

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert devices_at_ip == []
  end

  defp unique_test_ip do
    <<third, fourth, _rest::binary>> = :crypto.hash(:sha256, Ash.UUID.generate())
    "100.124.#{1 + rem(third, 250)}.#{1 + rem(fourth, 250)}"
  end
end
