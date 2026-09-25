defmodule ServiceRadar.Inventory.EphemeralDeviceExpiryTest do
  @moduledoc """
  Ephemeral devices -- no strong identifier -- expire on last-seen; a device holding a strong
  identifier never does, however long it is unseen (#4603).

  Each test builds devices through Ash, backdates `last_seen_time`, runs one expiry pass scoped
  to its own devices (so it cannot touch another test's rows) and reads the rows back.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.EphemeralDeviceExpiry
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  # One test's own scope is a handful of devices, all stale by construction, so the
  # mass-expiry guard is opened here and exercised on its own below.
  @settings %{
    ephemeral_expiry_enabled: true,
    ephemeral_expiry_days: 30,
    ephemeral_expiry_max_fraction: 1.0,
    batch_size: 100
  }

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:ephemeral_device_expiry_test)}
  end

  describe "eligible devices expire" do
    test "a device identified only by a randomized MAC, unseen past the window", %{actor: actor} do
      device = create_device!(actor)
      register!(actor, device.uid, :mac, laa_mac())
      backdate!(device.uid, 31)

      assert {:ok, %{expired: 1}} = run(actor, [device.uid])

      assert %Device{deleted_reason: "stale_ephemeral", deleted_by: by} =
               reload(actor, device.uid)

      assert by == "system:ephemeral_device_expiry"
    end

    test "an address-only device, unseen past the window", %{actor: actor} do
      device = create_device!(actor)
      backdate!(device.uid, 31)

      assert {:ok, %{expired: 1}} = run(actor, [device.uid])
      assert %Device{deleted_reason: "stale_ephemeral"} = reload(actor, device.uid)
    end

    test "a pass walks every batch, past devices it keeps", %{actor: actor} do
      kept = for _ <- 1..3, do: create_device!(actor, %{mac: global_mac()})
      ephemeral = for _ <- 1..3, do: create_device!(actor)
      all = kept ++ ephemeral
      # The kept devices are the oldest, so they fill the first batches.
      Enum.each(kept, &backdate!(&1.uid, 60))
      Enum.each(ephemeral, &backdate!(&1.uid, 31))

      assert {:ok, %{expired: 3, candidates: 6, excluded: 3}} =
               EphemeralDeviceExpiry.run(%{@settings | batch_size: 2}, actor,
                 uids: Enum.map(all, & &1.uid)
               )

      assert Enum.all?(kept, &live?(actor, &1.uid))
      refute Enum.any?(ephemeral, &live?(actor, &1.uid))
    end

    test "expiry is an identity transition: the revision moves", %{actor: actor} do
      device = create_device!(actor)
      backdate!(device.uid, 31)
      before = reload(actor, device.uid).identity_revision

      assert {:ok, %{expired: 1}} = run(actor, [device.uid])
      assert reload(actor, device.uid).identity_revision > before
    end

    test "an expired device seen again is restored through :restore, with a revival audit row",
         %{actor: actor} do
      device = create_device!(actor)
      backdate!(device.uid, 31)
      assert {:ok, %{expired: 1}} = run(actor, [device.uid])
      expired = reload(actor, device.uid)

      # The restore every discovery path uses (SweepResultsIngestor.restore_eligible_devices/2).
      assert %Ash.BulkResult{status: :success} =
               Device
               |> Ash.Query.for_read(:read, %{include_deleted: true})
               |> Ash.Query.filter(uid == ^device.uid)
               |> Ash.bulk_update(:restore, %{}, actor: actor, return_errors?: true)

      restored = reload(actor, device.uid)
      assert is_nil(restored.deleted_at)
      assert restored.identity_revision > expired.identity_revision
      assert revival_audit_reason(device.uid) == "stale_ephemeral"
    end
  end

  describe "devices that never expire" do
    test "a globally-unique MAC keeps a device however long it is unseen", %{actor: actor} do
      device = create_device!(actor)
      register!(actor, device.uid, :mac, global_mac())
      backdate!(device.uid, 3000)

      assert {:ok, %{expired: 0}} = run(actor, [device.uid])
      assert live?(actor, device.uid)
    end

    test "a globally-unique MAC among randomized ones keeps the device", %{actor: actor} do
      device = create_device!(actor)
      register!(actor, device.uid, :mac, laa_mac())
      register!(actor, device.uid, :mac, global_mac())
      backdate!(device.uid, 3000)

      assert {:ok, %{expired: 0}} = run(actor, [device.uid])
      assert live?(actor, device.uid)
    end

    test "a source-authoritative id keeps a device", %{actor: actor} do
      device = create_device!(actor)
      register!(actor, device.uid, :armis_device_id, "9#{unique()}")
      backdate!(device.uid, 3000)

      assert {:ok, %{expired: 0}} = run(actor, [device.uid])
      assert live?(actor, device.uid)
    end

    test "an agent keeps a device", %{actor: actor} do
      device = create_device!(actor, %{agent_id: "expiry-test-agent-#{unique()}"})
      backdate!(device.uid, 3000)

      assert {:ok, %{expired: 0}} = run(actor, [device.uid])
      assert live?(actor, device.uid)
    end

    test "a globally-unique MAC attribute keeps a device whose identifier rows are gone",
         %{actor: actor} do
      device = create_device!(actor, %{mac: global_mac()})
      backdate!(device.uid, 3000)

      assert {:ok, %{expired: 0}} = run(actor, [device.uid])
      assert live?(actor, device.uid)
    end

    test "a source id in metadata keeps a device", %{actor: actor} do
      device = create_device!(actor, %{metadata: %{"armis_device_id" => "9#{unique()}"}})
      backdate!(device.uid, 3000)

      assert {:ok, %{expired: 0}} = run(actor, [device.uid])
      assert live?(actor, device.uid)
    end

    test "an operator-created device is never expired", %{actor: actor} do
      device = create_device!(actor, %{discovery_sources: ["manual"]})
      backdate!(device.uid, 3000)

      assert {:ok, %{expired: 0}} = run(actor, [device.uid])
      assert live?(actor, device.uid)
    end

    test "a device seen inside the window is kept", %{actor: actor} do
      device = create_device!(actor)
      backdate!(device.uid, 29)

      assert {:ok, %{expired: 0}} = run(actor, [device.uid])
      assert live?(actor, device.uid)
    end

    test "a device matched by the exclusion query is kept", %{actor: actor} do
      device = create_device!(actor)
      backdate!(device.uid, 31)

      query_page = fn "in:devices tags.keep:true", _opts ->
        {:ok, %{rows: [%{"uid" => device.uid}], next_cursor: nil}}
      end

      settings =
        Map.put(@settings, :ephemeral_expiry_exclusion_query, "in:devices tags.keep:true")

      assert {:ok, %{expired: 0, excluded: 1}} =
               EphemeralDeviceExpiry.run(settings, actor,
                 uids: [device.uid],
                 query_page: query_page
               )

      assert live?(actor, device.uid)
    end

    test "an exclusion query that fails expires nothing", %{actor: actor} do
      device = create_device!(actor)
      backdate!(device.uid, 31)

      settings =
        Map.put(@settings, :ephemeral_expiry_exclusion_query, "in:devices tags.keep:true")

      query_page = fn _query, _opts -> {:error, :srql_unavailable} end

      assert {:error, {:exclusion_query_failed, _}} =
               EphemeralDeviceExpiry.run(settings, actor,
                 uids: [device.uid],
                 query_page: query_page
               )

      assert live?(actor, device.uid)
    end

    test "nothing expires when expiry is disabled", %{actor: actor} do
      device = create_device!(actor)
      backdate!(device.uid, 3000)

      assert {:ok, %{expired: 0}} =
               EphemeralDeviceExpiry.run(%{@settings | ephemeral_expiry_enabled: false}, actor,
                 uids: [device.uid]
               )

      assert live?(actor, device.uid)
    end
  end

  describe "the mass-expiry guard" do
    test "a pass that would expire more than the allowed fraction is refused", %{actor: actor} do
      stale = for _ <- 1..3, do: create_device!(actor)
      fresh = create_device!(actor)
      Enum.each(stale, &backdate!(&1.uid, 31))
      uids = Enum.map([fresh | stale], & &1.uid)

      settings = %{@settings | ephemeral_expiry_max_fraction: 0.5}

      assert {:error, {:mass_expiry_refused, %{candidates: 3, live: 4}}} =
               EphemeralDeviceExpiry.run(settings, actor, uids: uids)

      assert Enum.all?(stale, &live?(actor, &1.uid)), "a refused pass expires nothing"

      assert {:ok, %{expired: 3}} =
               EphemeralDeviceExpiry.run(
                 Map.put(settings, :ephemeral_expiry_guard_override, true),
                 actor,
                 uids: uids
               )

      assert live?(actor, fresh.uid)
    end
  end

  describe "settings" do
    test "the exclusion query must be SRQL that targets devices", %{actor: actor} do
      settings = settings!(actor)

      assert {:error, _} =
               DeviceCleanupSettings.update_settings(
                 settings,
                 %{ephemeral_expiry_exclusion_query: "in:interfaces if_name:eth0"},
                 actor: actor
               )

      assert {:ok, updated} =
               DeviceCleanupSettings.update_settings(
                 settings,
                 %{
                   ephemeral_expiry_exclusion_query: "in:devices hostname:%lab%",
                   ephemeral_expiry_days: 14
                 },
                 actor: actor
               )

      assert updated.ephemeral_expiry_days == 14
    end

    test "expiry is off unless an operator turns it on", %{actor: actor} do
      refute settings!(actor).ephemeral_expiry_enabled
    end
  end

  defp run(actor, uids), do: EphemeralDeviceExpiry.run(@settings, actor, uids: uids)

  defp settings!(actor) do
    case DeviceCleanupSettings.get_settings(actor: actor) do
      {:ok, %DeviceCleanupSettings{} = settings} -> settings
      _ -> DeviceCleanupSettings.create_settings!(%{}, actor: actor)
    end
  end

  defp reload(actor, uid) do
    {:ok, device} = Device.get_by_uid(uid, true, actor: actor)
    device
  end

  defp live?(actor, uid), do: is_nil(reload(actor, uid).deleted_at)

  defp revival_audit_reason(uid) do
    %{rows: rows} =
      Repo.query!(
        "SELECT previous_deleted_reason FROM platform.device_revival_audit WHERE device_uid = $1",
        [uid]
      )

    case rows do
      [[reason] | _] -> reason
      _ -> nil
    end
  end

  defp create_device!(actor, attrs \\ %{}) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{uid: "sr:" <> Ecto.UUID.generate(), hostname: "expiry-test", ip: unique_ip()},
        attrs
      )
    )
    |> Ash.create!(actor: actor)
  end

  defp backdate!(uid, days) do
    Repo.query!(
      "UPDATE platform.ocsf_devices SET last_seen_time = now() - make_interval(days => $2) " <>
        "WHERE uid = $1",
      [uid, days]
    )
  end

  defp register!(actor, uid, type, value) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, %{
      device_id: uid,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      source: "test"
    })
    |> Ash.create!(actor: actor)
  end

  defp unique, do: System.unique_integer([:positive])

  # Documentation-range addresses (RFC 5737) and MACs under the documentation OUI (RFC 7042):
  # 00-00-5E-00-53 globally unique, 02-00-5E-00-53 with the locally-administered bit set.
  defp unique_ip, do: "192.0.2.#{rem(unique(), 254) + 1}"
  defp global_mac, do: "00005E0053" <> Base.encode16(<<rem(unique(), 256)>>)
  defp laa_mac, do: "02005E0053" <> Base.encode16(<<rem(unique(), 256)>>)
end
