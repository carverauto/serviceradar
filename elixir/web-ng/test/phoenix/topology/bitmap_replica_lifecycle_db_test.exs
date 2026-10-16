defmodule ServiceRadarWebNG.Topology.BitmapReplicaLifecycleDBTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Inventory.FleetIdentity
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Topology.BitmapExpression
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapPublisher
  alias ServiceRadarWebNG.Topology.BitmapSource
  alias ServiceRadarWebNG.Topology.Native

  @moduletag :topology_atlas_db
  @moduletag timeout: 180_000
  @actor SystemActor.system(:bitmap_replica_lifecycle_test)
  @authority <<23::256>>

  setup do
    # Separate connections and real commits are essential: a shared sandbox
    # transaction would make the supposedly invisible insertion visible to readers.
    :ok = Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: 240_000)
    suffix = Ecto.UUID.generate()
    ids = Enum.map(~w(first second late higher restarted), &("sr:bitmap-replica-#{suffix}-" <> &1))
    vendor = "bitmap-replica-#{suffix}"

    previous =
      Map.new(
        [:god_view_enabled, :topology_bitmap_enabled, :bitmap_tag_keys],
        &{&1, Application.fetch_env(:serviceradar_web_ng, &1)}
      )

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)
    Application.put_env(:serviceradar_web_ng, :topology_bitmap_enabled, true)
    Application.put_env(:serviceradar_web_ng, :bitmap_tag_keys, [])

    on_exit(fn ->
      try do
        Repo.query!("SELECT platform.refresh_device_inventory_rollups()")

        Repo.update_all(from(d in Device, where: d.uid in ^ids),
          set: [deleted_at: DateTime.utc_now(), deleted_reason: "synthetic replica fixture cleanup"]
        )

        records = Repo.all(from(d in Device, where: d.uid in ^ids, select: %{uid: d.uid}))
        count = length(records)
        assert {%{errors: 0}, ^count} = DeviceCleanupWorker.hard_delete_records(%{deleted: 0, errors: 0}, records)
        assert [] == Repo.all(from(d in Device, where: d.uid in ^ids and is_nil(d.identity_purged_at), select: d.uid))
      after
        Sandbox.mode(Repo, :manual)

        Enum.each(previous, fn
          {key, {:ok, value}} -> Application.put_env(:serviceradar_web_ng, key, value)
          {key, :error} -> Application.delete_env(:serviceradar_web_ng, key)
        end)
      end
    end)

    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})

    start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: __MODULE__.IsolatedPubSub}, id: :isolated_pubsub))

    %{ids: ids, vendor: vendor}
  end

  test "one accepted revision combines current address sources, removes replacements, and fails explicitly on incomplete input",
       %{
         ids: [first_id, second_id | _],
         vendor: vendor
       } do
    first = create(first_id, vendor, true)
    second = create(second_id, vendor, true)
    Repo.update_all(from(d in Device, where: d.uid == ^first.uid), set: [ip: "192.0.2.7"])
    Repo.update_all(from(d in Device, where: d.uid == ^second.uid), set: [ip: "192.0.2.8"])
    first_ordinal = FleetIdentity.device_ordinal(first.uid)
    second_ordinal = FleetIdentity.device_ordinal(second.uid)

    create_resource(Interface, %{
      device_id: second.uid,
      interface_uid: "example-shared",
      timestamp: DateTime.utc_now(),
      ip_addresses: ["192.0.2.7"]
    })

    active_alias =
      DeviceAliasState
      |> Ash.Changeset.for_create(:detect, %{device_id: first.uid, alias_type: :ip, alias_value: "198.51.100.7"},
        actor: @actor
      )
      |> Ash.create!()

    interface =
      create_resource(Interface, %{
        device_id: first.uid,
        interface_uid: "example-port",
        timestamp: DateTime.utc_now(),
        ip_addresses: ["2001:db8::7", "192.0.2.9"]
      })

    host = create_resource(VirtualizationHost, %{provider: "example", provider_ref: first.uid, name: "Synthetic host"})

    nic =
      create_resource(VirtualizationNetworkInterface, %{
        provider: "example",
        provider_ref: first.uid,
        name: "example-nic",
        host_id: host.id,
        device_uid: first.uid,
        exists: true,
        active: false,
        address: "203.0.113.7/24",
        ip_addresses: []
      })

    on_exit(fn ->
      Repo.delete_all(from(n in VirtualizationNetworkInterface, where: n.host_id == ^host.id))
      Repo.delete_all(from(h in VirtualizationHost, where: h.id == ^host.id))
    end)

    {:ok, info} = BitmapSource.initialize()
    epoch = <<42::128>>
    {:ok, index} = Native.bitmap_index_new(info.dictionary_epoch, epoch, :device, info.supported_facets)
    current = Map.merge(info, %{device: index, index_epoch: epoch})
    on_exit(fn -> Native.bitmap_index_close(index) end)
    ordinals = [first_ordinal, second_ordinal]

    assert {:ok, _} = publish_addresses(current, ordinals, 1)

    for {cidr, expected} <- [
          {"192.0.2.7", Enum.sort(ordinals)},
          {"192.0.2.8", [second_ordinal]},
          {"192.0.2.9", [first_ordinal]},
          {"198.51.100.7", [first_ordinal]},
          {"2001:db8::/64", [first_ordinal]},
          {"203.0.113.7", [first_ordinal]},
          {"203.0.113.0", []}
        ] do
      assert {:ok, ^expected} = address_members(current, cidr)
    end

    active_alias |> Ash.Changeset.for_update(:mark_stale, %{}, actor: @actor) |> Ash.update!()
    Ash.destroy!(interface, actor: @actor)
    nic |> Ash.Changeset.for_update(:update, %{exists: false}, actor: @actor) |> Ash.update!()
    assert {:ok, _} = publish_addresses(current, [first_ordinal], 2)

    for cidr <- ["192.0.2.9", "198.51.100.7", "2001:db8::7", "203.0.113.7"] do
      assert {:ok, []} = address_members(current, cidr)
    end

    page_addresses = Enum.map(1..0x1F5, &"2001:db8::#{Integer.to_string(&1, 16)}")

    Repo.query!(
      "INSERT INTO platform.discovered_interfaces (device_id, interface_uid, timestamp, ip_addresses) VALUES ($1, 'example-page', now(), $2::text[])",
      [first.uid, page_addresses]
    )

    assert {:ok, _} = publish_addresses(current, [first_ordinal], 3)

    for address <- page_addresses do
      assert {:ok, [^first_ordinal]} = address_members(current, address <> "/128")
    end

    Repo.query!(
      "DELETE FROM platform.discovered_interfaces WHERE device_id = $1 AND interface_uid = 'example-page'",
      [first.uid]
    )

    assert {:ok, _} = publish_addresses(current, [first_ordinal], 4)

    for address <- page_addresses do
      assert {:ok, []} = address_members(current, address <> "/128")
    end

    assert {:ok, primary} = address_members(current, "192.0.2.7")
    assert primary == Enum.sort(ordinals)

    Repo.query!(
      "INSERT INTO platform.discovered_interfaces (device_id, interface_uid, timestamp, ip_addresses) VALUES ($1, 'example-cap', now(), $2::text[])",
      [first.uid, List.duplicate("192.0.2.99", 4_097)]
    )

    assert {:ok, _} = publish_addresses(current, [first_ordinal], 5)
    assert {:error, "ip_unavailable"} = address_members(current, "192.0.2.7")
    Repo.update_all(from(d in Device, where: d.uid == ^second.uid), set: [vendor_name: "example-updated"])
    assert {:ok, _} = publish_addresses(current, [second_ordinal], 6)
    assert {:error, "ip_unavailable"} = address_members(current, "192.0.2.7")
    assert {:ok, [^second_ordinal]} = selected_members(current, %{"facet" => "vendor", "value" => "example-updated"})
    assert {:ok, %{ready: true, ip_available: false}} = Native.bitmap_index_status(index)
  end

  test "independent publishers recover missed notifications, late commits behind the cursor, and a cold restart", %{
    ids: [first_id, second_id, late_id, higher_id, restarted_id],
    vendor: vendor
  } do
    first = create(first_id, vendor, true)
    second = create(second_id, vendor, false)
    one = start_replica(:one, ServiceRadar.PubSub)
    two = start_replica(:two, __MODULE__.IsolatedPubSub)
    first_ordinal = FleetIdentity.device_ordinal(first.uid)
    second_ordinal = FleetIdentity.device_ordinal(second.uid)
    await_members(one, vendor, [first_ordinal])
    await_members(two, vendor, [first_ordinal])

    set_available(first, false)
    set_available(second, true)
    await_members(one, vendor, [second_ordinal])
    # This publisher never subscribes to the notifier's PubSub. It must converge
    # through its production periodic keyset scan without an injected rescan event.
    await_members(two, vendor, [second_ordinal])

    parent = self()
    token = make_ref()
    [[reader_backend]] = Repo.query!("SELECT pg_backend_pid()").rows

    writer =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: 120_000)

        try do
          Repo.transaction(
            fn ->
              # Bulk ingestion bypasses the singleton count-row lock. Keep the
              # identity triggers active to exercise that commit-ordering path;
              # cleanup refreshes the rollups before purging the synthetic rows.
              Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")

              Repo.query!(
                "INSERT INTO platform.ocsf_devices (uid, vendor_name, is_available) VALUES ($1, $2, true)",
                [late_id, vendor]
              )

              [[writer_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {:allocated_uncommitted, token, writer_backend, FleetIdentity.device_ordinal(late_id)})

              receive do
                {:commit, ^token} -> :ok
              after
                90_000 -> raise "late-commit fixture was not released"
              end
            end,
            timeout: 100_000
          )
        after
          Sandbox.checkin(Repo)
        end
      end)

    try do
      assert_receive {:allocated_uncommitted, ^token, writer_backend, late_ordinal}, 10_000
      refute reader_backend == writer_backend
      assert is_integer(late_ordinal) and late_ordinal > 0
      higher = create(higher_id, vendor, true)
      higher_ordinal = FleetIdentity.device_ordinal(higher.uid)
      assert late_ordinal < higher_ordinal
      assert nil == FleetIdentity.device_ordinal(late_id)

      # Observing the higher ordinal on the isolated publisher proves its scan
      # passed the uncommitted identity. Allocation order is not commit order.
      await_members(two, vendor, [second_ordinal, higher_ordinal])
      send(writer.pid, {:commit, token})
      assert {:ok, :ok} = Task.await(writer, 10_000)
      expected = Enum.sort([second_ordinal, late_ordinal, higher_ordinal])
      await_members(one, vendor, expected)
      await_members(two, vendor, expected)

      {:ok, previous} = BitmapIndex.snapshot(two)
      :ok = stop_supervised({:replica, :two})
      assert {:ok, %{ready: false, cardinality: 0}} = Native.bitmap_index_status(previous.device)
      restarted = create(restarted_id, vendor, true)
      replacement = start_owner(:two, __MODULE__.IsolatedPubSub, __MODULE__.TwoTasks)
      await_members(replacement, vendor, Enum.sort([FleetIdentity.device_ordinal(restarted.uid) | expected]))
      {:ok, current} = BitmapIndex.snapshot(replacement)
      assert current.dictionary_epoch == previous.dictionary_epoch
      refute current.index_epoch == previous.index_epoch
    after
      if Process.alive?(writer.pid), do: Task.shutdown(writer, :brutal_kill)
    end
  end

  defp start_replica(id, pubsub) do
    name = if id == :one, do: __MODULE__.OneTasks, else: __MODULE__.TwoTasks
    start_supervised!(Supervisor.child_spec({Task.Supervisor, name: name, max_children: 1}, id: {:tasks, id}))
    start_owner(id, pubsub, name)
  end

  defp start_owner(id, pubsub, tasks) do
    start_supervised!(Supervisor.child_spec({BitmapIndex, task_supervisor: tasks, pubsub: pubsub}, id: {:replica, id}))
  end

  defp create(uid, vendor, available) do
    Device
    |> Ash.Changeset.for_create(:create, %{uid: uid, vendor_name: vendor, is_available: available}, actor: @actor)
    |> Ash.create!()
  end

  defp create_resource(resource, attrs),
    do: resource |> Ash.Changeset.for_create(:create, attrs, actor: @actor) |> Ash.create!()

  defp publish_addresses(current, ordinals, sequence) do
    BitmapPublisher.publish(
      current,
      fn ->
        with {:ok, rows} <- BitmapSource.fetch(ordinals, current.supported_facets), do: {:ok, %{rows: rows}}
      end,
      fn _ -> true end,
      sequence
    )
  end

  defp address_members(current, cidr) do
    selected_members(current, %{"ip_cidr" => cidr})
  end

  defp selected_members(current, expression) do
    {:ok, parsed} = BitmapExpression.parse(%{"expression" => expression}, current.supported_facets)

    with {:ok, {query, _, _, _}} <-
           Native.bitmap_index_query(
             current.device,
             current.dictionary_epoch,
             current.index_epoch,
             :device,
             @authority,
             parsed.program,
             1_000
           ) do
      try do
        Native.bitmap_query_page(query, @authority, 0, 128, 1_000)
      after
        Native.bitmap_query_close(query)
      end
    end
  end

  defp set_available(device, value) do
    device |> Ash.Changeset.for_update(:set_availability, %{is_available: value}, actor: @actor) |> Ash.update!()
  end

  defp await_members(owner, vendor, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 45_000
    actual = members(owner, vendor)

    cond do
      actual == {:ok, expected} ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("replica membership did not converge: #{inspect(actual)}")

      true ->
        Process.sleep(25)
        await_members(owner, vendor, expected, deadline)
    end
  end

  defp members(owner, vendor) do
    with {:ok, snapshot} <- BitmapIndex.snapshot(owner),
         {:ok, parsed} <-
           BitmapExpression.parse(
             %{
               "expression" => %{
                 "all" => [%{"facet" => "vendor", "value" => vendor}, %{"facet" => "availability", "value" => "healthy"}]
               }
             },
             snapshot.supported_facets
           ),
         {:ok, {query, _revision, _source, count}} <-
           Native.bitmap_index_query(
             snapshot.device,
             snapshot.dictionary_epoch,
             snapshot.index_epoch,
             :device,
             @authority,
             parsed.program,
             1_000
           ) do
      try do
        with {:ok, ordinals} <- Native.bitmap_query_page(query, @authority, 0, 128, 1_000) do
          assert count == length(ordinals)
          {:ok, ordinals}
        end
      after
        Native.bitmap_query_close(query)
      end
    end
  end
end
