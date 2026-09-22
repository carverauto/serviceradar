defmodule ServiceRadar.Inventory.SyncIngestorIpConflictTest do
  @moduledoc """
  Regression coverage for active-IP unique-index handling in bulk device upserts.

  Source-authoritative integration identifiers must not be rebound to whichever
  unrelated device currently owns an IP. Contested IPs are dropped from the
  incoming strong device (pre-resolved before insert when the holder is already
  visible, or via reactive recovery on a true race). Same-batch handoffs must
  free the relinquished IP for the new claimant rather than clearing it.

  Interactive device edits (`Device :update`, GitHub #4357) take the same
  index through the atomic single-record path: a taken IP must surface as an
  `ip` "has already been taken" validation error instead of
  `Ash.Error.Unknown`. Inactive and stale holders retain their addresses
  when a conflicting update is rejected.
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Address
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
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

    # Reactive unique-violation path must not fire for a stable, already-visible
    # holder (#4796). Outcome assertions below are the source of truth.
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
      integration_update(first_id, ip, "first-incoming"),
      integration_update(second_id, ip, "second-incoming")
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

    # Neither strong identity may silently win the free IP by record order.
    assert devices_at_ip == []
  end

  test "same-batch handoff moves IP from previous owner to new strong claimant", %{
    actor: actor
  } do
    ip_x = unique_test_ip()
    ip_y = unique_test_ip()
    owner_id = "owner-#{System.unique_integer([:positive])}"
    claimer_id = "claimer-#{System.unique_integer([:positive])}"

    # Seed owner A on X through the real ingest path so identifiers exist.
    assert :ok =
             SyncIngestor.ingest_updates(
               [integration_update(owner_id, ip_x, "owner-a")],
               actor: actor
             )

    owner_uid = device_uid_for_integration!(owner_id, actor)
    {:ok, %Device{ip: ^ip_x}} = Device.get_by_uid(owner_uid, false, actor: actor)

    # One batch: A moves X→Y while new strong B claims X.
    updates = [
      integration_update(owner_id, ip_y, "owner-a-moved"),
      integration_update(claimer_id, ip_x, "claimer-b")
    ]

    assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)

    claimer_uid = device_uid_for_integration!(claimer_id, actor)
    assert claimer_uid != owner_uid

    {:ok, owner} = Device.get_by_uid(owner_uid, false, actor: actor)
    {:ok, claimer} = Device.get_by_uid(claimer_uid, false, actor: actor)

    assert owner.ip == ip_y
    assert claimer.ip == ip_x

    {:ok, at_x} =
      Device
      |> Ash.Query.filter(ip == ^ip_x and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert Enum.map(at_x, & &1.uid) == [claimer_uid]
  end

  test "same-batch blank-IP clear frees the slot for a new strong claimant", %{
    actor: actor
  } do
    ip_x = unique_test_ip()
    owner_id = "blank-owner-#{System.unique_integer([:positive])}"
    claimer_id = "blank-claimer-#{System.unique_integer([:positive])}"

    assert :ok =
             SyncIngestor.ingest_updates(
               [integration_update(owner_id, ip_x, "owner-a")],
               actor: actor
             )

    owner_uid = device_uid_for_integration!(owner_id, actor)

    # A→"" is an explicit clear under upsert SQL (not omit/keep). B must inherit X.
    updates = [
      integration_update(owner_id, "", "owner-a-cleared"),
      integration_update(claimer_id, ip_x, "claimer-b")
    ]

    assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)

    claimer_uid = device_uid_for_integration!(claimer_id, actor)
    {:ok, owner} = Device.get_by_uid(owner_uid, false, actor: actor)
    {:ok, claimer} = Device.get_by_uid(claimer_uid, false, actor: actor)

    # Upsert SQL maps blank EXCLUDED.ip to NULL, not empty string.
    assert owner.ip == nil
    assert claimer.ip == ip_x

    {:ok, at_x} =
      Device
      |> Ash.Query.filter(ip == ^ip_x and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert Enum.map(at_x, & &1.uid) == [claimer_uid]
  end

  test "plugin inventory snapshot AWX host keeps identity without stealing live IP", %{
    actor: actor
  } do
    ip = unique_test_ip()
    integration_id = "awx:host:host-#{System.unique_integer([:positive])}"

    {:ok, agent_device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "agent-holder",
        ip: ip
      })
      |> Ash.create(actor: actor)

    # Complete plugin inventories strip integration_* from ocsf_devices.metadata
    # but still register typed identifiers — model that path, not the thin
    # metadata-only shape.
    update = %{
      "ip" => ip,
      "hostname" => "awx-host",
      "source" => "awx",
      "metadata" => %{
        "integration_type" => "plugin_device_discovery",
        "integration_id" => integration_id,
        "plugin_inventory_snapshot" => true
      }
    }

    for _ <- 1..3 do
      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)
    end

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value == ^integration_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{device_id: awx_uid}] = List.wrap(identifiers)
    assert awx_uid != agent_device.uid

    {:ok, awx_device} = Device.get_by_uid(awx_uid, false, actor: actor)
    assert awx_device.ip == nil
    # Snapshot path must not leave integration_id on the device row.
    refute is_map(awx_device.metadata) and Map.has_key?(awx_device.metadata, "integration_id")

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert Enum.map(devices_at_ip, & &1.uid) == [agent_device.uid]
  end

  test "concurrent distinct strong identities race on a free IP without dual holders", %{
    actor: actor
  } do
    ip = unique_test_ip()
    first_id = "race-a-#{System.unique_integer([:positive])}"
    second_id = "race-b-#{System.unique_integer([:positive])}"

    # Barrier after both prechecks complete (not merely task entry), so both
    # writers observe a free IP before either insert_all runs.
    parent = self()
    barrier = make_ref()
    precheck_count = :atomics.new(1, signed: false)

    previous_hooks = Application.get_env(:serviceradar_core, :device_writes_test_hooks)

    Application.put_env(:serviceradar_core, :device_writes_test_hooks, %{
      after_active_ip_precheck: fn ->
        n = :atomics.add_get(precheck_count, 1, 1)

        if n <= 2 do
          send(parent, {:precheck_done, barrier, n})

          receive do
            {:go, ^barrier} -> :ok
          after
            10_000 -> flunk("post-precheck barrier timeout")
          end
        end
      end
    })

    on_exit(fn ->
      case previous_hooks do
        nil -> Application.delete_env(:serviceradar_core, :device_writes_test_hooks)
        hooks -> Application.put_env(:serviceradar_core, :device_writes_test_hooks, hooks)
      end
    end)

    task_a =
      Task.async(fn ->
        SyncIngestor.ingest_updates(
          [integration_update(first_id, ip, "race-a")],
          actor: actor
        )
      end)

    task_b =
      Task.async(fn ->
        SyncIngestor.ingest_updates(
          [integration_update(second_id, ip, "race-b")],
          actor: actor
        )
      end)

    assert_receive {:precheck_done, ^barrier, 1}, 10_000
    assert_receive {:precheck_done, ^barrier, 2}, 10_000
    send(task_a.pid, {:go, barrier})
    send(task_b.pid, {:go, barrier})

    assert :ok = Task.await(task_a, 30_000)
    assert :ok = Task.await(task_b, 30_000)

    first_uid = device_uid_for_integration!(first_id, actor)
    second_uid = device_uid_for_integration!(second_id, actor)
    assert first_uid != second_uid

    {:ok, first} = Device.get_by_uid(first_uid, false, actor: actor)
    {:ok, second} = Device.get_by_uid(second_uid, false, actor: actor)

    holders =
      [first, second]
      |> Enum.filter(fn device -> device.ip == ip end)
      |> Enum.map(& &1.uid)

    # Exactly one survivor: free-IP races must not leave the address unowned
    # and must not dual-hold under the unique active-IP index.
    assert length(holders) == 1

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert length(devices_at_ip) == 1
    assert hd(devices_at_ip).uid in [first_uid, second_uid]
  end

  describe "interactive device update IP conflicts (GitHub #4357)" do
    test "update reports a usable ip error when another active device owns the IP", %{
      actor: actor
    } do
      {taken_ip, free_ip} = doc_ip_pair()
      _holder = create_device!(actor, "4357-holder", taken_ip)
      subject = create_device!(actor, "4357-subject", free_ip)

      assert {:error, %Invalid{errors: errors}} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert Enum.any?(errors, &ip_taken_error?/1)
    end

    test "update preserves an inactive holder and reports a usable ip error", %{actor: actor} do
      {taken_ip, free_ip} = doc_ip_pair()
      holder = create_device!(actor, "4357-inactive-holder", taken_ip)
      subject = create_device!(actor, "4357-inactive-subject", free_ip)

      {:ok, _} = Device.mark_inactive(holder, actor: actor)

      assert {:error, %Invalid{errors: errors}} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert Enum.any?(errors, &ip_taken_error?/1)

      assert {:ok, %Device{ip: ^taken_ip}} =
               Device.get_by_uid(holder.uid, false, actor: actor)

      assert {:ok, %Device{ip: ^free_ip}} =
               Device.get_by_uid(subject.uid, false, actor: actor)
    end

    test "update preserves a stale holder and reports a usable ip error", %{actor: actor} do
      {taken_ip, free_ip} = doc_ip_pair()
      holder = create_device!(actor, "4357-stale-holder", taken_ip)
      subject = create_device!(actor, "4357-stale-subject", free_ip)

      stale_at =
        DateTime.utc_now()
        |> DateTime.add(-30 * 24 * 3600, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_naive()

      {:ok, _} =
        Repo.query("UPDATE platform.ocsf_devices SET last_seen_time = $1 WHERE uid = $2", [
          stale_at,
          holder.uid
        ])

      assert {:error, %Invalid{errors: errors}} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert Enum.any?(errors, &ip_taken_error?/1)

      assert {:ok, %Device{ip: ^taken_ip}} =
               Device.get_by_uid(holder.uid, false, actor: actor)

      assert {:ok, %Device{ip: ^free_ip}} =
               Device.get_by_uid(subject.uid, false, actor: actor)
    end

    test "update keeps working when resubmitting the device's own IP", %{actor: actor} do
      {ip, _free_ip} = doc_ip_pair()
      subject = create_device!(actor, "4357-self", ip)

      assert {:ok, updated} =
               subject
               |> Ash.Changeset.for_update(:update, %{hostname: "4357-renamed", ip: ip})
               |> Ash.update(actor: actor)

      assert updated.hostname == "4357-renamed"
      assert updated.ip == ip
    end

    test "update succeeds when the previous holder was soft-deleted", %{actor: actor} do
      {taken_ip, free_ip} = doc_ip_pair()
      holder = create_device!(actor, "4357-deleted-holder", taken_ip)
      subject = create_device!(actor, "4357-deleted-subject", free_ip)

      {:ok, _} = Device.soft_delete(holder, "test-retired", "test", actor: actor)

      assert {:ok, updated} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert updated.ip == taken_ip
    end

    test "update succeeds when the requested IP is unassigned", %{actor: actor} do
      {new_ip, old_ip} = doc_ip_pair()
      subject = create_device!(actor, "4357-free-subject", old_ip)

      assert {:ok, updated} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: new_ip})
               |> Ash.update(actor: actor)

      assert updated.ip == new_ip

      assert {:ok, %Device{ip: ^new_ip}} =
               Device.get_by_uid(subject.uid, false, actor: actor)
    end

    test "same IP in another partition does not conflict", %{actor: actor} do
      {taken_ip, free_ip} = doc_ip_pair()

      other =
        create_device!(actor, "4357-other-partition", taken_ip, %{partition: "test-partition"})

      subject = create_device!(actor, "4357-partition-subject", free_ip)

      assert {:ok, updated} =
               subject
               |> Ash.Changeset.for_update(:update, %{ip: taken_ip})
               |> Ash.update(actor: actor)

      assert updated.ip == taken_ip

      assert {:ok, %Device{ip: ^taken_ip}} =
               Device.get_by_uid(other.uid, false, actor: actor)
    end
  end

  describe "primary address preference (GitHub #3905)" do
    test "the SQL rank and the Elixir rank agree", %{actor: _actor} do
      # Two implementations exist on purpose: the upsert must compare against
      # the CURRENT row, which only SQL sees, while alias/in-memory decisions
      # need it in Elixir. Two implementations drift unless something pins them,
      # so this is that something.
      addresses = [
        "8.8.8.8",
        "152.117.116.178",
        "10.0.0.5",
        "192.168.1.1",
        "172.16.0.1",
        "172.15.0.1",
        "172.32.0.1",
        "100.64.0.1",
        "127.0.0.1",
        "169.254.1.1",
        "0.0.0.0",
        "2001:4860:4860::8888",
        "::1",
        "::",
        "fd2f:420a:24b1:1:f692:bfff:fe75:c72a",
        "fe80::f692:bfff:fe75:c72b",
        "fe90::1",
        "febf::1",
        "fec0::1",
        "fc00::1",
        "fdff::1",
        "::ffff:192.168.1.1",
        "::ffff:8.8.8.8",
        # Forms real collectors actually send: SNMP reports link-locals with a
        # zone, and interface addresses arrive in CIDR form.
        "fe80::1%eth0",
        "192.168.1.1/24",
        "0.0.0.0/0",
        "  10.0.0.5  ",
        "not-an-ip",
        ""
      ]

      %{rows: rows} =
        Repo.query!(
          "SELECT a, platform.sr_address_rank(a) FROM unnest($1::text[]) AS a",
          [addresses]
        )

      sql_ranks = Map.new(rows, fn [address, rank] -> {address, rank} end)

      mismatched =
        Enum.filter(addresses, fn address ->
          Address.rank(address) != Map.fetch!(sql_ranks, address)
        end)

      assert mismatched == [],
             "SQL and Elixir rankings disagree for: " <>
               Enum.map_join(mismatched, ", ", fn address ->
                 "#{address} (elixir=#{Address.rank(address)} sql=#{Map.fetch!(sql_ranks, address)})"
               end)
    end

    test "a link-local sighting does not overwrite a routable primary", %{actor: actor} do
      mac = unique_universal_mac()
      routable = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, routable)], actor: actor)
      assert device_ip_for_mac(mac, actor) == routable

      # This is the #3905 mechanism: NDP census sightings arrive carrying a
      # link-local, and before the rank guard they replaced the primary.
      assert :ok =
               SyncIngestor.ingest_updates(
                 [mac_update(mac, "fe80::f692:bfff:fe75:c72b")],
                 actor: actor
               )

      assert device_ip_for_mac(mac, actor) == routable,
             "a link-local sighting clobbered the routable primary"
    end

    test "an equal-ranked address DOES apply, because that is a real re-IP", %{actor: actor} do
      # The rule is never-downgrade, not only-promote. alma-test01 moved
      # 192.168.2.243 -> 192.168.1.171; both are private, and refusing equal
      # ranks would freeze every device at its first address.
      mac = unique_universal_mac()
      first = unused_private_ip()
      second = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, first)], actor: actor)
      assert device_ip_for_mac(mac, actor) == first

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, second)], actor: actor)

      assert device_ip_for_mac(mac, actor) == second,
             "a same-class re-IP was refused; devices would freeze at their first address"
    end

    test "a public-to-private re-address is NOT refused", %{actor: actor} do
      # global outranks private in Identity.Address, which is right when choosing
      # among addresses known at once. Applying that to the upsert would freeze a
      # host that genuinely moved from a public to an RFC1918 address on its
      # stale public one -- so the downgrade check collapses both into one
      # routable tier.
      mac = unique_universal_mac()
      public_ip = "203.0.113.#{:rand.uniform(200) + 20}"
      private_ip = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, public_ip)], actor: actor)
      assert device_ip_for_mac(mac, actor) == public_ip

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, private_ip)], actor: actor)

      assert device_ip_for_mac(mac, actor) == private_ip,
             "a genuine public->private re-address was refused; the device would be frozen on a stale public address"
    end

    test "a ULA still cannot overwrite a routable primary", %{actor: actor} do
      mac = unique_universal_mac()
      routable = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, routable)], actor: actor)

      assert :ok =
               SyncIngestor.ingest_updates(
                 [mac_update(mac, "fd2f:420a:24b1:1:f692:bfff:fe75:c7ef")],
                 actor: actor
               )

      assert device_ip_for_mac(mac, actor) == routable,
             "a ULA clobbered a routable primary"
    end

    test "a routable address promotes a link-local primary", %{actor: actor} do
      mac = unique_universal_mac()
      link_local = "fe80::f692:bfff:fe75:c7ab"
      routable = unused_private_ip()

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, link_local)], actor: actor)
      assert device_ip_for_mac(mac, actor) == link_local

      assert :ok = SyncIngestor.ingest_updates([mac_update(mac, routable)], actor: actor)

      assert device_ip_for_mac(mac, actor) == routable,
             "a routable address did not promote over a link-local primary"
    end

    test "a device with only link-local addresses keeps one", %{actor: actor} do
      # 8 of the 18 affected devices have no routable address at all. Leaving
      # them with no address would trade a poor answer for none.
      mac = unique_universal_mac()

      assert :ok =
               SyncIngestor.ingest_updates(
                 [mac_update(mac, "fe80::f692:bfff:fe75:c7cd")],
                 actor: actor
               )

      assert :ok =
               SyncIngestor.ingest_updates(
                 [mac_update(mac, "fe80::f692:bfff:fe75:c7ce")],
                 actor: actor
               )

      assert device_ip_for_mac(mac, actor) in [
               "fe80::f692:bfff:fe75:c7cd",
               "fe80::f692:bfff:fe75:c7ce"
             ]
    end
  end

  # `sweep` is a mapper_like_source?, so SourcePolicy.include_mac_identifier?/1
  # only admits the MAC when identity_mac_kind names a real chassis address --
  # without it the MAC is an observation and no device is keyed by it.
  defp mac_update(mac, ip) do
    %{
      "ip" => ip,
      "mac" => mac,
      "source" => "sweep",
      "metadata" => %{
        "identity_mac" => mac,
        "identity_mac_kind" => "primary"
      }
    }
  end

  # unique_test_ip/0 does not consult the database, so two of these tests drew
  # the same address and collided on ocsf_devices_unique_active_ip_idx.
  defp unused_private_ip do
    fn -> System.unique_integer([:positive, :monotonic]) end
    |> Stream.repeatedly()
    |> Enum.find_value(fn n ->
      ip = "10.#{rem(div(n, 65_025), 250) + 1}.#{rem(div(n, 255), 250) + 1}.#{rem(n, 250) + 1}"

      case Repo.query("SELECT 1 FROM platform.ocsf_devices WHERE ip = $1 LIMIT 1", [ip]) do
        {:ok, %{rows: []}} -> ip
        _ -> nil
      end
    end)
  end

  defp device_ip_for_mac(mac, actor) do
    normalized = mac |> String.replace(":", "") |> String.upcase()

    %{rows: rows} =
      Repo.query!(
        """
        SELECT d.ip
        FROM platform.ocsf_devices d
        JOIN platform.device_identifiers i ON i.device_id = d.uid
        WHERE i.identifier_type = 'mac' AND i.identifier_value = $1
        """,
        [normalized]
      )

    case rows do
      [[ip]] ->
        ip

      other ->
        flunk(
          "expected exactly one device for #{mac}, got #{inspect(other)} (actor #{inspect(actor)})"
        )
    end
  end

  defp unique_universal_mac do
    [:positive]
    |> System.unique_integer()
    |> Integer.to_string(16)
    |> String.pad_leading(10, "0")
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&("A8:" <> &1))
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

  defp device_uid_for_integration!(integration_id, actor) do
    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value == ^integration_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{device_id: uid}] = List.wrap(identifiers)
    uid
  end

  # Monotonic, not a random draw: the hash-of-a-UUID version could repeat, and a repeated
  # address is indistinguishable from the conflict this file exists to test.
  defp unique_test_ip do
    n = System.unique_integer([:positive, :monotonic])
    "100.124.#{rem(div(n, 254), 254) + 1}.#{rem(n, 254) + 1}"
  end

  # Documentation-range pair from a single monotonic draw. The two addresses
  # are in different /24s, so they can never equal each other: an intra-test
  # collision is always the conflict under test, never the fixture.
  defp doc_ip_pair do
    n = System.unique_integer([:positive, :monotonic])
    {"203.0.113.#{rem(n, 254) + 1}", "198.51.100.#{rem(n, 254) + 1}"}
  end

  defp create_device!(actor, hostname, ip, extra \\ %{}) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{uid: "sr:4357-#{Ecto.UUID.generate()}", hostname: hostname, ip: ip}, extra)
      )
      |> Ash.create(actor: actor)

    device
  end

  defp ip_taken_error?(error) do
    fields = List.wrap(Map.get(error, :fields) || []) ++ List.wrap(Map.get(error, :field))
    :ip in fields and Map.get(error, :message) == "has already been taken"
  end
end
