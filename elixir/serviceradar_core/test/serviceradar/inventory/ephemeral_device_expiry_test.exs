defmodule ServiceRadar.Inventory.EphemeralDeviceExpiryTest do
  @moduledoc """
  Ephemeral devices -- no strong identifier -- expire on last-seen; a device holding a strong
  identifier never does, however long it is unseen (#4603).

  Each test builds devices through Ash, backdates `last_seen_time`, runs one expiry pass scoped
  to its own devices (so it cannot touch another test's rows) and reads the rows back.
  """

  use ServiceRadar.DataCase, async: true

  import ExUnit.CaptureLog

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

  @source_id_keys ["agent_id", "armis_device_id", "integration_id", "netbox_device_id"]

  @doc false
  # Runs in the process that emits the event; a test hears only its own pass, though async
  # tests in other modules may run expiry passes of their own at the same time.
  def forward_event([_, _, _, kind], measurements, _metadata, parent) do
    if self() == parent, do: send(parent, {:ephemeral_expiry, kind, measurements})
  end

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

      assert {:ok,
              %{
                candidates: 6,
                kept_by_evidence: 3,
                kept_by_exclusion: 0,
                eligible: 3,
                expired: 3,
                skipped_at_delete: 0
              }} =
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

      # Held by the SQL rule, so it is not even a candidate.
      assert {:ok, %{candidates: 0, expired: 0}} = run(actor, [device.uid])
      assert live?(actor, device.uid)
    end

    test "a numeric source id in metadata keeps a device", %{actor: actor} do
      device = create_device!(actor, %{metadata: %{"armis_device_id" => 9_000 + unique()}})
      backdate!(device.uid, 3000)
      assert metadata_type(device.uid, "armis_device_id") == "number"

      assert {:ok, %{candidates: 0, expired: 0}} = run(actor, [device.uid])
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

      assert {:ok, %{kept_by_exclusion: 1, kept_by_evidence: 0, eligible: 0, expired: 0}} =
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

      {result, log} =
        with_log(fn ->
          with_expiry_events(fn -> EphemeralDeviceExpiry.run(settings, actor, uids: uids) end)
        end)

      assert {:error,
              {:mass_expiry_refused,
               %{candidates: 3, eligible: 3, live: 4, max_fraction: 0.5} = counts}} = result

      refute Map.has_key?(counts, :expired)
      assert log =~ "pass refused (mass_deletion): it would expire 3 of 4 live devices"
      assert log =~ "stays set, lifting this guard for every later pass, until it is cleared"

      assert_received {:ephemeral_expiry, :refused,
                       %{candidates: 3, eligible: 3, live_devices: 4}}

      refute_received {:ephemeral_expiry, :run, _measurements}
      assert Enum.all?(stale, &live?(actor, &1.uid)), "a refused pass expires nothing"

      assert {:ok, %{expired: 3}} =
               EphemeralDeviceExpiry.run(
                 Map.put(settings, :ephemeral_expiry_guard_override, true),
                 actor,
                 uids: uids
               )

      assert live?(actor, fresh.uid)
    end

    test "the guard judges the devices a pass would expire, not its candidates",
         %{actor: actor} do
      # Three candidates the attribute check keeps; one pass would expire one device of five.
      kept = for _ <- 1..3, do: create_device!(actor, %{mac: global_mac()})
      ephemeral = create_device!(actor)
      fresh = create_device!(actor)
      Enum.each([ephemeral | kept], &backdate!(&1.uid, 31))
      uids = Enum.map([fresh, ephemeral | kept], & &1.uid)

      assert {:ok,
              %{candidates: 4, kept_by_evidence: 3, kept_by_exclusion: 0, eligible: 1, expired: 1}} =
               EphemeralDeviceExpiry.run(
                 %{@settings | ephemeral_expiry_max_fraction: 0.5},
                 actor,
                 uids: uids
               )

      refute live?(actor, ephemeral.uid)
      assert Enum.all?([fresh | kept], &live?(actor, &1.uid))
    end
  end

  describe "the delete statement" do
    test "a source id that reaches the metadata after the read holds the device", %{actor: actor} do
      by_string = create_device!(actor)
      by_number = create_device!(actor)
      uids = [by_string.uid, by_number.uid]
      Enum.each(uids, &backdate!(&1, 31))

      late = %{
        by_string.uid => %{"armis_device_id" => "9#{unique()}"},
        by_number.uid => %{"netbox_device_id" => 9_000 + unique()}
      }

      before_delete = fn eligible ->
        send(self(), {:before_delete, Enum.sort(eligible)})
        Enum.each(eligible, &merge_metadata!(&1, Map.fetch!(late, &1)))
      end

      assert {:ok, %{candidates: 2, eligible: 2, expired: 0, skipped_at_delete: 2}} =
               EphemeralDeviceExpiry.run(@settings, actor,
                 uids: uids,
                 before_delete: before_delete
               )

      assert_received {:before_delete, eligible}
      assert eligible == Enum.sort(uids)
      assert metadata_type(by_number.uid, "netbox_device_id") == "number"
      assert Enum.all?(uids, &live?(actor, &1))
    end

    test "the strong-identifier function holds every source id key, as a string or a number",
         %{actor: actor} do
      device = create_device!(actor)

      for key <- @source_id_keys, value <- ["x#{unique()}", "  x  ", 42, 4.2] do
        set_metadata!(device.uid, %{key => value})

        assert holds_strong_identifier?(device.uid),
               "#{key} => #{inspect(value)} should hold the device"
      end
    end

    test "the strong-identifier function holds nothing for an empty or non-scalar value",
         %{actor: actor} do
      device = create_device!(actor)

      for key <- @source_id_keys,
          value <- ["", "   ", "\t\n", nil, true, false, %{"id" => "x"}, ["x"]] do
        set_metadata!(device.uid, %{key => value})

        refute holds_strong_identifier?(device.uid),
               "#{key} => #{inspect(value)} should not hold the device"
      end

      for metadata <- [%{}, %{"integration_type" => "armis"}, %{"source_id" => "x"}] do
        set_metadata!(device.uid, metadata)

        refute holds_strong_identifier?(device.uid),
               "#{inspect(metadata)} should not hold the device"
      end
    end
  end

  describe "the counters" do
    test "each counter counts its own devices, alike in the result and the telemetry",
         %{actor: actor} do
      by_evidence = for _ <- 1..3, do: create_device!(actor, %{mac: global_mac()})
      # A device the exclusion query matches counts there even when its evidence would keep it.
      by_exclusion = [create_device!(actor), create_device!(actor, %{mac: global_mac()})]
      skipped = for _ <- 1..4, do: create_device!(actor)
      expiring = create_device!(actor)
      all = by_evidence ++ by_exclusion ++ skipped ++ [expiring]
      uids = Enum.map(all, & &1.uid)
      Enum.each(uids, &backdate!(&1, 31))

      excluded = Enum.map(by_exclusion, &%{"uid" => &1.uid})

      query_page = fn "in:devices tags.keep:true", _opts ->
        {:ok, %{rows: excluded, next_cursor: nil}}
      end

      skipped_uids = MapSet.new(skipped, & &1.uid)

      before_delete = fn eligible ->
        eligible
        |> Enum.filter(&MapSet.member?(skipped_uids, &1))
        |> Enum.each(&merge_metadata!(&1, %{"integration_id" => "late-#{unique()}"}))
      end

      settings =
        Map.merge(@settings, %{
          ephemeral_expiry_exclusion_query: "in:devices tags.keep:true",
          batch_size: 3
        })

      assert {:ok, counts} =
               with_expiry_events(fn ->
                 EphemeralDeviceExpiry.run(settings, actor,
                   uids: uids,
                   query_page: query_page,
                   before_delete: before_delete
                 )
               end)

      assert counts == %{
               candidates: 10,
               kept_by_evidence: 3,
               kept_by_exclusion: 2,
               eligible: 5,
               expired: 1,
               skipped_at_delete: 4
             }

      assert_received {:ephemeral_expiry, :run, ^counts}
      refute live?(actor, expiring.uid)
      assert Enum.all?(by_evidence ++ by_exclusion ++ skipped, &live?(actor, &1.uid))
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

  defp holds_strong_identifier?(uid) do
    %{rows: [[held]]} =
      Repo.query!("SELECT platform.device_holds_strong_identifier($1)", [uid])

    held
  end

  defp set_metadata!(uid, metadata) do
    Repo.query!("UPDATE platform.ocsf_devices SET metadata = $2::jsonb WHERE uid = $1", [
      uid,
      metadata
    ])
  end

  defp merge_metadata!(uid, patch) do
    Repo.query!(
      "UPDATE platform.ocsf_devices SET metadata = COALESCE(metadata, '{}'::jsonb) || $2::jsonb " <>
        "WHERE uid = $1",
      [uid, patch]
    )
  end

  defp metadata_type(uid, key) do
    %{rows: [[type]]} =
      Repo.query!(
        "SELECT jsonb_typeof(metadata -> $2::text) FROM platform.ocsf_devices WHERE uid = $1",
        [uid, key]
      )

    type
  end

  # Runs `fun` with the expiry events forwarded to this process, and detaches before it returns.
  defp with_expiry_events(fun) do
    handler_id = "ephemeral-expiry-events-#{unique()}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:serviceradar, :inventory, :ephemeral_expiry, :run],
          [:serviceradar, :inventory, :ephemeral_expiry, :refused]
        ],
        &__MODULE__.forward_event/4,
        self()
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

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

  # The live-IP unique index spans every async test in the run, and a /24 pool is small enough for
  # two tests to draw the same host, so addresses come from the IPv6 documentation range (RFC 3849).
  defp unique_ip do
    n = unique()
    hi = Integer.to_string(div(n, 65_536), 16)
    lo = Integer.to_string(rem(n, 65_536), 16)
    "2001:db8:4603::#{hi}:#{lo}"
  end

  # MACs under the documentation OUI (RFC 7042): 00-00-5E-00-53 globally unique,
  # 02-00-5E-00-53 with the locally-administered bit set.
  defp global_mac, do: "00005E0053" <> Base.encode16(<<rem(unique(), 256)>>)
  defp laa_mac, do: "02005E0053" <> Base.encode16(<<rem(unique(), 256)>>)
end
