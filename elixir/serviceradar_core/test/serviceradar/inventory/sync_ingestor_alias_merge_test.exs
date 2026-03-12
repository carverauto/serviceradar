defmodule ServiceRadar.Inventory.SyncIngestorAliasMergeTest do
  @moduledoc """
  Integration coverage for alias-conflict merges during sync ingestion.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState

  alias ServiceRadar.Inventory.{
    Device,
    DeviceIdentifier,
    IdentityReconciler,
    MergeAudit,
    SyncIngestor
  }

  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_alias_merge_test)
    {:ok, actor: actor}
  end

  test "sync ingestion merges alias device into canonical device for non-mapper source", %{
    actor: actor
  } do
    ip = unique_test_ip(1)
    mac = "AA:BB:CC:DD:EE:01"
    agent_id = "alias-merge-agent-#{System.unique_integer([:positive])}"

    {:ok, canonical} = create_device(actor, "canonical")
    {:ok, alias_device} = create_device(actor, "alias")

    assert {:ok, _} = register_identifier(actor, canonical.uid, :agent_id, agent_id)

    {:ok, alias_state} = create_alias_state(actor, alias_device.uid, ip)
    assert {:ok, _} = DeviceAliasState.confirm(alias_state, actor: actor)

    update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "tonka01",
      "source" => "agent",
      "metadata" => %{"agent_id" => agent_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    assert {:ok, _} = Device.get_by_uid(canonical.uid, false, actor: actor)

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip)
      |> Ash.read(actor: actor)
      |> ServiceRadar.Ash.Page.unwrap()

    assert Enum.count(devices_at_ip) == 1
    remaining_uid = hd(devices_at_ip).uid
    assert remaining_uid in [canonical.uid, alias_device.uid]

    merged_uid =
      [canonical.uid, alias_device.uid]
      |> Enum.reject(&(&1 == remaining_uid))
      |> List.first()

    assert {:ok, [audit | _]} = MergeAudit.get_merged_to(merged_uid, actor: actor)
    assert audit.to_device_id == remaining_uid
  end

  test "mapper source does not merge alias device by mac-only identifier", %{actor: actor} do
    ip = unique_test_ip(2)
    mac = "AA:BB:CC:DD:EE:02"
    normalized_mac = IdentityReconciler.normalize_mac(mac)

    {:ok, canonical} = create_device(actor, "canonical-mapper")
    {:ok, alias_device} = create_device(actor, "alias-mapper")

    assert {:ok, _} = register_identifier(actor, canonical.uid, :mac, normalized_mac)

    {:ok, alias_state} = create_alias_state(actor, alias_device.uid, ip)
    assert {:ok, _} = DeviceAliasState.confirm(alias_state, actor: actor)

    update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "mapper-tonka",
      "source" => "mapper"
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    assert {:ok, _} = Device.get_by_uid(alias_device.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(canonical.uid, false, actor: actor)
    assert {:ok, []} = MergeAudit.get_merged_to(alias_device.uid, actor: actor)
  end

  defp create_device(actor, hostname) do
    uniq = System.unique_integer([:positive, :monotonic])

    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: unique_test_ip(uniq)
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp register_identifier(actor, device_id, type, value) do
    attrs = %{
      device_id: device_id,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      source: "test"
    }

    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, attrs)
    |> Ash.create(actor: actor)
  end

  defp create_alias_state(actor, device_id, ip) do
    attrs = %{
      device_id: device_id,
      partition: "default",
      alias_type: :ip,
      alias_value: ip,
      metadata: %{"source" => "test"}
    }

    DeviceAliasState.create_detected(attrs, actor: actor)
  end

  defp unique_test_ip(seed) do
    third = rem(seed, 250) + 1
    fourth = rem(div(seed, 250), 250) + 1
    "198.19.#{third}.#{fourth}"
  end
end
