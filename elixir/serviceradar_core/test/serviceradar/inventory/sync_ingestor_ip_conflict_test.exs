defmodule ServiceRadar.Inventory.SyncIngestorIpConflictTest do
  @moduledoc """
  Regression coverage for active-IP unique-index handling in bulk device upserts.

  Source-authoritative integration identifiers must not be rebound to whichever
  unrelated device currently owns an IP. Contested IPs are dropped from the
  incoming strong device (pre-resolved before insert when the holder is already
  visible, or via reactive recovery on a true race).
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

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

  test "preserves generic integration identity when active-IP is already held", %{
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

    log =
      capture_log(fn ->
        assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
      end)

    # Known holders are resolved before insert_all so recurring syncs do not
    # trip ocsf_devices_unique_active_ip_idx on every cycle (#4796). CaptureLog
    # may omit :info depending on the test logger level; the regression signal
    # is that the reactive unique-violation path never fires.
    refute log =~ "Bulk device upsert hit active-IP conflict"
    refute log =~ "ocsf_devices_unique_active_ip_idx"

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

  test "pre-resolves a batch with colliding strong identities without choosing an IP owner", %{
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

    log =
      capture_log(fn ->
        assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)
      end)

    refute log =~ "Bulk device upsert hit active-IP conflict"
    refute log =~ "ocsf_devices_unique_active_ip_idx"

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

  test "repeated strong IP claims against a live holder stay successful and quiet", %{
    actor: actor
  } do
    ip = unique_test_ip()
    integration_id = "awx-host-#{System.unique_integer([:positive])}"

    {:ok, _agent_device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "agent-holder",
        ip: ip
      })
      |> Ash.create(actor: actor)

    update = %{
      "ip" => ip,
      "hostname" => "awx-host",
      "source" => "awx",
      "metadata" => %{
        "integration_type" => "plugin_device_discovery",
        "integration_id" => integration_id
      }
    }

    # Simulate the recurring AWX host inventory sync that previously warned on
    # every cycle for the same active-IP collision (#4796).
    for _ <- 1..3 do
      log =
        capture_log(fn ->
          assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
        end)

      refute log =~ "Bulk device upsert hit active-IP conflict"
      refute log =~ "ocsf_devices_unique_active_ip_idx"
    end

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value == ^integration_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{device_id: awx_uid}] = List.wrap(identifiers)
    {:ok, awx_device} = Device.get_by_uid(awx_uid, false, actor: actor)
    assert awx_device.ip == nil
  end

  defp unique_test_ip do
    <<third, fourth, _rest::binary>> = :crypto.hash(:sha256, Ash.UUID.generate())
    "100.124.#{1 + rem(third, 250)}.#{1 + rem(fourth, 250)}"
  end
end
