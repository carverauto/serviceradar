defmodule ServiceRadar.Inventory.SyncIngestorAliasMergeTest do
  @moduledoc """
  Integration coverage for alias-conflict merges during sync ingestion.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.InterfaceMacs
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

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
    refute remaining_uid == alias_device.uid

    assert {:ok, [audit | _]} = MergeAudit.get_merged_to(alias_device.uid, actor: actor)
    refute audit.to_device_id == alias_device.uid
  end

  test "mapper source does not merge alias device by mac-only identifier", %{actor: actor} do
    ip = unique_test_ip(2)
    mac = unique_mac(2)
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

  describe "chassis corroboration narrows the distinct-MAC veto" do
    test "two devices with disjoint MACs still conflict when neither claims the other", %{
      actor: actor
    } do
      {:ok, a} = create_device(actor, "chassis-a")
      {:ok, b} = create_device(actor, "chassis-b")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "F492BF75C721")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "F492BF75C72B")

      # The default and correct answer: two universally-administered MACs that
      # differ are two pieces of hardware. Nothing about this change may weaken
      # it -- a recycled IP rebinding to a different host depends on it.
      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end

    test "the veto lifts when one device's own interface table claims the other's MAC", %{
      actor: actor
    } do
      {:ok, a} = create_device(actor, "chassis-wan")
      {:ok, b} = create_device(actor, "chassis-lan")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "F492BF75C721")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "F492BF75C72B")
      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)

      # The chassis itself, over authenticated SNMP, reports ...C72B as one of
      # its own interfaces. That is direct evidence these are two addresses of
      # one device rather than two devices.
      assert InterfaceMacs.register(a.uid, ["f4:92:bf:75:c7:2b"], nil, actor) == 1

      refute AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor),
             "an own-interface claim on the other device's MAC should lift the veto"
    end

    test "the claim works in either direction", %{actor: actor} do
      {:ok, a} = create_device(actor, "chassis-x")
      {:ok, b} = create_device(actor, "chassis-y")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "F492BF75C731")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "F492BF75C73B")

      assert InterfaceMacs.register(b.uid, ["f4:92:bf:75:c7:31"], nil, actor) == 1

      refute AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end

    test "an unrelated interface MAC does not lift the veto", %{actor: actor} do
      {:ok, a} = create_device(actor, "chassis-p")
      {:ok, b} = create_device(actor, "chassis-q")

      assert {:ok, _} = register_identifier(actor, a.uid, :mac, "F492BF75C741")
      assert {:ok, _} = register_identifier(actor, b.uid, :mac, "F492BF75C74B")

      # A device claiming its own other interfaces must NOT make it look like
      # every other device. Only a claim on the OTHER device's MAC counts.
      assert InterfaceMacs.register(a.uid, ["f4:92:bf:75:c7:99"], nil, actor) == 1

      assert AliasGuard.distinct_mac_conflict?(a.uid, b.uid, actor)
    end
  end

  describe "interface MAC registration" do
    test "two rows of ONE chassis can both claim the same MAC", %{actor: actor} do
      # The defect this table exists to fix. Two device rows that are the same
      # chassis report the SAME interface MACs. Under a globally-unique identifier
      # the first to register owned every one and the twin owned none -- observed
      # on farm01 as 11 MACs on one row and 0 on the twin that reported 16. The
      # loser then re-attempted every MAC on every poll forever, each attempt
      # silently updating the other device's row and counting as a success.
      {:ok, a} = create_device(actor, "chassis-wan-side")
      {:ok, b} = create_device(actor, "chassis-lan-side")

      shared = "f4:92:bf:75:c7:81"

      assert InterfaceMacs.register(a.uid, [shared], nil, actor) == 1
      assert InterfaceMacs.register(b.uid, [shared], nil, actor) == 1

      assert MapSet.member?(InterfaceMacs.registered_values(a.uid, actor), "F492BF75C781")

      assert MapSet.member?(InterfaceMacs.registered_values(b.uid, actor), "F492BF75C781"),
             "the second device could not claim a MAC the first already claimed"
    end

    test "the change gate still holds for the second claimant", %{actor: actor} do
      # The scale consequence of the old defect: the loser's own set always read
      # back empty, so it never converged and wrote on every poll. At 1M devices
      # duplicates are the common case, which is exactly where steady-state zero
      # was claimed.
      {:ok, a} = create_device(actor, "chassis-first")
      {:ok, b} = create_device(actor, "chassis-second")

      shared = "f4:92:bf:75:c7:82"

      assert InterfaceMacs.register(a.uid, [shared], nil, actor) == 1
      assert InterfaceMacs.register(b.uid, [shared], nil, actor) == 1

      assert InterfaceMacs.register(b.uid, [shared], nil, actor) == 0,
             "the second claimant re-wrote a MAC it already holds; its change gate never engages"
    end

    test "refuses locally-administered addresses", %{actor: actor} do
      {:ok, device} = create_device(actor, "virtualized-host")

      # tap/veth/dummy/bridge addresses are overwhelmingly locally administered,
      # and a synthesised address is not evidence of hardware. On the deployment
      # that motivated this, the filter removed 14 of 67 interface MACs.
      assert InterfaceMacs.eligible(["02:6e:4e:5c:13:14", "f6:92:bf:75:c7:21"]) == []

      assert InterfaceMacs.register(device.uid, ["02:6e:4e:5c:13:14"], nil, actor) == 0
      assert MapSet.size(InterfaceMacs.registered_values(device.uid, actor)) == 0
    end

    test "writes nothing when a poll discovers nothing new", %{actor: actor} do
      {:ok, device} = create_device(actor, "polled-switch")
      macs = ["f4:92:bf:75:c7:51", "f4:92:bf:75:c7:52"]

      assert InterfaceMacs.register(device.uid, macs, nil, actor) == 2

      # The change gate. Without it, 1M devices polled 15x/day would upsert
      # hundreds of millions of rows/day for values that change only when
      # hardware does.
      assert InterfaceMacs.register(device.uid, macs, nil, actor) == 0
      assert InterfaceMacs.register(device.uid, macs ++ ["f4:92:bf:75:c7:53"], nil, actor) == 1
    end

    test "normalizes separators and case", %{actor: actor} do
      {:ok, device} = create_device(actor, "mixed-format")

      assert InterfaceMacs.register(device.uid, ["f4-92-bf-75-c7-61"], nil, actor) == 1
      assert InterfaceMacs.register(device.uid, ["F4:92:BF:75:C7:61"], nil, actor) == 0

      assert MapSet.member?(InterfaceMacs.registered_values(device.uid, actor), "F492BF75C761")
    end

    test "ignores malformed addresses rather than raising", %{actor: actor} do
      {:ok, device} = create_device(actor, "bad-data")

      assert InterfaceMacs.eligible(["", "not-a-mac", nil, "f4:92:bf"]) == []
      assert InterfaceMacs.register(device.uid, ["", "zz", nil], nil, actor) == 0
    end
  end

  defp create_device(actor, hostname) do
    uniq = System.unique_integer([:positive, :monotonic])

    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: unique_device_ip(uniq)
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
    "100.122.#{third}.#{fourth}"
  end

  defp unique_device_ip(seed) do
    third = rem(seed, 250) + 1
    fourth = rem(div(seed, 250), 250) + 1
    "100.123.#{third}.#{fourth}"
  end

  defp unique_mac(seed) do
    suffix = rem(System.unique_integer([:positive, :monotonic]) + seed, 255)

    "AA:BB:CC:DD:EE:#{suffix |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()}"
  end
end
