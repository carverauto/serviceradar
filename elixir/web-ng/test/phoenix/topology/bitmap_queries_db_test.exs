defmodule ServiceRadarWebNG.Topology.BitmapQueriesDBTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ChannelTest

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.FleetIdentity
  alias ServiceRadar.NetworkDiscovery.World
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.Native, as: PrefixNative
  alias ServiceRadar.PrefixTags.Registry
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Topology.BitmapAuthority
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapPrefixTags
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapQueryAdmission
  alias ServiceRadarWebNG.Topology.BitmapQueryTasks
  alias ServiceRadarWebNG.Topology.BitmapSelection
  alias ServiceRadarWebNG.Topology.BitmapSource
  alias ServiceRadarWebNG.Topology.BitmapView
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.TileWatchTasks
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldHealth
  alias ServiceRadarWebNG.Topology.WorldOverlay
  alias ServiceRadarWebNG.Topology.WorldTile
  alias ServiceRadarWebNGWeb.Endpoint
  alias ServiceRadarWebNGWeb.TopologyQueryController
  alias ServiceRadarWebNGWeb.TopologyTileChannel
  alias ServiceRadarWebNGWeb.TopologyTileController
  alias ServiceRadarWebNGWeb.UserSocket

  @endpoint Endpoint
  @version "00000000-0000-4000-8000-000000000613"
  @moduletag :topology_atlas_db
  @actor SystemActor.system(:bitmap_query_database_test)

  setup do
    :ok = Sandbox.checkout(Repo, isolation: "REPEATABLE READ")
    :ok = Sandbox.mode(Repo, {:shared, self()})

    previous =
      Map.new(
        [:god_view_enabled, :bitmap_tag_keys],
        &{&1, Application.fetch_env(:serviceradar_web_ng, &1)}
      )

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)
    Application.put_env(:serviceradar_web_ng, :bitmap_tag_keys, ["rack"])

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_web_ng, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_web_ng, key)
      end)
    end)

    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    # Channel joins subscribe through the endpoint's own PubSub server.
    start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: ServiceRadarWebNG.PubSub}, id: :web_pubsub))
    %{cohort: "bitmap-query-" <> Ecto.UUID.generate()}
  end

  test "typed source projects canonical fields and configured scalar tags without retaining arbitrary device payloads", %{
    cohort: cohort
  } do
    tag_keys = ["rack", "maintenance", "flag", "count", "ratio", "label", "nested", "list", "empty"]
    Application.put_env(:serviceradar_web_ng, :bitmap_tag_keys, tag_keys)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :bitmap_tag_keys, ["rack"]) end)

    scalar_tags = %{
      "rack" => "example-rack",
      "unconfigured" => String.duplicate("q", 100_000),
      "maintenance" => true,
      "flag" => false,
      "count" => 0,
      "ratio" => 1.5,
      "label" => "true",
      "nested" => %{"child" => true},
      "list" => ["true"],
      "empty" => nil
    }

    device =
      create("sr:bitmap-source", %{
        vendor_name: " ExampleVendor ",
        region: cohort,
        vlan_uid: "example-vlan",
        type_id: 10,
        os: %{"name" => "ExampleOS", "version" => "2", "unused" => String.duplicate("z", 100_000)},
        tags: scalar_tags,
        is_available: false
      })

    ordinal = FleetIdentity.device_ordinal(device.uid)
    assert {:ok, facets} = BitmapSource.supported_facets(:device)
    assert {:ok, [{^ordinal, true, values}]} = BitmapSource.fetch([ordinal], facets)

    assert Map.new(values) == %{
             "vendor" => "ExampleVendor",
             "region" => cohort,
             "vlan" => "example-vlan",
             "device_class" => "10",
             "os_name" => "ExampleOS",
             "os_version" => "2",
             "availability" => "unavailable",
             "tag:rack" => "example-rack",
             "tag:maintenance" => "true",
             "tag:flag" => "false",
             "tag:count" => "0",
             "tag:ratio" => "1.5",
             "tag:label" => "true"
           }

    twin =
      create("sr:bitmap-source-text", %{
        region: cohort,
        tags: %{
          "maintenance" => "true",
          "flag" => "false",
          "count" => "0",
          "ratio" => "1.5",
          "label" => "true"
        },
        is_available: true
      })

    retained =
      create("sr:bitmap-source-retained", %{
        region: cohort,
        tags: %{"rack" => "other", "nested" => %{"child" => true}, "list" => ["true"], "empty" => nil},
        is_available: true
      })

    create("sr:bitmap-source-unrelated", %{region: "outside-" <> cohort, tags: scalar_tags})
    create("sr:bitmap-source-unrelated-missing", %{region: "outside-" <> cohort})

    twin_ordinal = FleetIdentity.device_ordinal(twin.uid)
    retained_ordinal = FleetIdentity.device_ordinal(retained.uid)
    assert {:ok, [{^retained_ordinal, true, retained_values}]} = BitmapSource.fetch([retained_ordinal], facets)
    retained_values = Map.new(retained_values)
    assert retained_values["tag:rack"] == "other"
    refute Map.has_key?(retained_values, "tag:nested")
    refute Map.has_key?(retained_values, "tag:list")
    refute Map.has_key?(retained_values, "tag:empty")
    refute Map.has_key?(retained_values, "tag:maintenance")

    user =
      User
      |> Ash.Changeset.for_create(:create, %{email: "bitmap-scalar-tags@example.com", role: :viewer}, actor: @actor)
      |> Ash.create!()

    scope = Scope.for_user(user)
    start_supervised!({Endpoint, []})
    tasks = start_supervised!({Task.Supervisor, max_children: 1})
    owner = start_supervised!({BitmapIndex, name: BitmapIndex, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    start_supervised!(BitmapQueries)
    await(fn -> BitmapIndex.snapshot() end, &match?({:ok, _}, &1))

    assert_ordinals = fn expression, expected ->
      params = %{"expression" => within_cohort(cohort, expression), "limit" => 16}

      await(fn -> BitmapQueries.run(scope, params) end, fn
        {:ok, %{ordinals: ordinals, total: total}} ->
          total == length(expected) and Enum.sort(ordinals) == Enum.sort(expected)

        _ ->
          false
      end)
    end

    assert_ordinals.(%{"facet" => "tag:maintenance", "value" => "true"}, [ordinal, twin_ordinal])
    assert_ordinals.(%{"facet" => "tag:flag", "value" => "false"}, [ordinal, twin_ordinal])
    assert_ordinals.(%{"facet" => "tag:count", "value" => "0"}, [ordinal, twin_ordinal])
    assert_ordinals.(%{"facet" => "tag:ratio", "value" => "1.5"}, [ordinal, twin_ordinal])
    assert_ordinals.(%{"facet" => "tag:label", "value" => "true"}, [ordinal, twin_ordinal])
    assert_ordinals.(%{"facet" => "tag:count", "prefix" => "0"}, [ordinal, twin_ordinal])
    assert_ordinals.(%{"facet" => "tag:ratio", "prefix" => "1"}, [ordinal, twin_ordinal])

    assert_ordinals.(
      %{"except" => %{"facet" => "tag:maintenance", "value" => "true"}},
      [retained_ordinal]
    )

    Repo.update_all(
      from(d in Device, where: d.uid == ^device.uid),
      set: [tags: Map.delete(scalar_tags, "maintenance")]
    )

    send(owner, :devices_rescan)
    assert_ordinals.(%{"facet" => "tag:maintenance", "value" => "true"}, [twin_ordinal])

    assert_ordinals.(
      %{"except" => %{"facet" => "tag:maintenance", "value" => "true"}},
      [ordinal, retained_ordinal]
    )

    Repo.update_all(from(d in Device, where: d.uid == ^device.uid), set: [tags: scalar_tags])

    Repo.update_all(from(d in Device, where: d.uid == ^device.uid), set: [source_retired_at: DateTime.utc_now()])
    assert {:ok, [{^ordinal, false, []}]} = BitmapSource.fetch([ordinal], facets)
    assert FleetIdentity.device_ordinal(device.uid) == ordinal
    Repo.update_all(from(d in Device, where: d.uid == ^device.uid), set: [source_retired_at: nil])
    assert {:ok, [{^ordinal, true, ^values}]} = BitmapSource.fetch([ordinal], facets)

    device
    |> Ash.Changeset.for_update(:soft_delete, %{deleted_reason: "synthetic bitmap lifecycle"}, actor: @actor)
    |> Ash.update!()

    assert {:ok, [{^ordinal, false, []}]} = BitmapSource.fetch([ordinal], facets)
    assert {:ok, %{entries: identities}} = BitmapSource.identity_page(ordinal - 1)
    assert {device.uid, ordinal} in identities

    # A reserved identity from an older writer remains durable even though
    # service components are outside the network-device query universe.
    component = create("serviceradar:bitmap-" <> Ecto.UUID.generate(), %{})

    %{rows: [[reserved]]} =
      Repo.query!(
        """
        INSERT INTO platform.device_fleet_ordinals(uid) VALUES ($1)
        ON CONFLICT (uid) DO UPDATE SET uid = EXCLUDED.uid
        RETURNING ordinal
        """,
        [component.uid]
      )

    assert {:ok, []} = BitmapSource.resolve_ids([component.uid])
    assert {:ok, [{^reserved, false, []}]} = BitmapSource.fetch([reserved], facets)
    assert {:ok, %{entries: identities}} = BitmapSource.identity_page(reserved - 1)
    refute Enum.any?(identities, fn {uid, _} -> uid == component.uid end)

    assert %{rows: [[^reserved]]} =
             Repo.query!("SELECT ordinal FROM platform.device_fleet_ordinals WHERE uid = $1", [component.uid])
  end

  test "real owner repairs unhinted writes, pages current membership, and rechecks revoked authority before delivery", %{
    cohort: cohort
  } do
    first = create("sr:bitmap-first", %{vendor_name: "example-a", region: cohort})
    removed = create("sr:bitmap-removed", %{vendor_name: "example-a", region: cohort})
    excluded = create("sr:bitmap-excluded", %{vendor_name: "example-b", region: cohort})
    create("sr:bitmap-unrelated", %{vendor_name: "example-a", region: "outside-" <> cohort})

    user =
      User
      |> Ash.Changeset.for_create(:create, %{email: "bitmap-viewer@example.com", role: :viewer}, actor: @actor)
      |> Ash.create!()

    scope = Scope.for_user(user)
    start_supervised!({Endpoint, []})
    tasks = start_supervised!({Task.Supervisor, max_children: 1})
    owner = start_supervised!({BitmapIndex, name: BitmapIndex, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    start_supervised!(BitmapQueries)
    await(fn -> BitmapIndex.snapshot() end, &match?({:ok, _}, &1))

    values_params = %{"facet" => "region", "search" => cohort, "limit" => "1"}
    response = TopologyQueryController.values(binary_conn(scope), values_params)
    assert response.status == 200

    assert %{"items" => [%{"value" => ^cohort, "count" => 3}], "cursor" => value_cursor} =
             Jason.decode!(response.resp_body)

    assert is_binary(value_cursor)

    expression = within_cohort(cohort, %{"facet" => "vendor", "value" => "example-a"})
    params = %{"expression" => expression, "limit" => 1, "facets" => [%{"facet" => "vendor", "value" => "example-a"}]}
    first_ordinal = FleetIdentity.device_ordinal(first.uid)

    assert {:ok, %{ordinals: [^first_ordinal], total: 2, cursor: cursor, facets: [%{count: 2}]}} =
             BitmapQueries.run(scope, params)

    assert {:error, :not_found} =
             BitmapSelection.authorize(scope, %{"query" => Jason.encode!(expression)}, [excluded.uid])

    # This raw writer emits no PubSub event. A complete keyset pass must repair
    # membership without treating modified_time or allocation order as a commit watermark.
    Repo.update_all(from(d in Device, where: d.uid == ^removed.uid), set: [vendor_name: "example-b"])
    added = create("sr:bitmap-added", %{vendor_name: "example-a", region: cohort})
    added_ordinal = FleetIdentity.device_ordinal(added.uid)
    send(owner, :devices_rescan)

    await(
      fn -> BitmapQueries.run(scope, Map.put(params, "cursor", cursor)) end,
      &match?({:ok, %{ordinals: [^added_ordinal], total: 2}}, &1)
    )

    assert {:error, :forbidden} =
             BitmapQueries.with_query(scope, expression, fn _context ->
               user |> Ash.Changeset.for_update(:deactivate, %{}, actor: @actor) |> Ash.update!()
               {:ok, :must_not_be_delivered}
             end)

    assert {:error, :forbidden} = BitmapQueries.run(scope, params)

    response = TopologyQueryController.values(binary_conn(scope), Map.put(values_params, "cursor", value_cursor))
    assert response.status == 403
    assert Jason.decode!(response.resp_body) == %{"error" => "forbidden"}

    {:ok, snapshot} = BitmapIndex.snapshot()
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, false)
    assert {:error, :bitmap_disabled} = BitmapIndex.snapshot()
    assert {:ok, %{ready: false, cardinality: 0}} = Native.bitmap_index_status(snapshot.device)
  end

  test "real channel projects admitted Arrow rows and binary HTTP preserves authority before cached delivery", %{
    cohort: cohort
  } do
    included = create("sr:bitmap-map-included", %{vlan_uid: "20", is_available: true, region: cohort})
    excluded = create("sr:bitmap-map-excluded", %{vlan_uid: "30", is_available: false, region: cohort})
    create("sr:bitmap-map-unrelated", %{vlan_uid: "20", region: "outside-" <> cohort})

    user =
      User
      |> Ash.Changeset.for_create(:create, %{email: "bitmap-map-viewer@example.com", role: :viewer}, actor: @actor)
      |> Ash.create!()

    scope = Scope.for_user(user)
    start_supervised!({Endpoint, []})
    tasks = start_supervised!({Task.Supervisor, name: TileWatchTasks, max_children: 8})
    start_supervised!({BitmapIndex, name: BitmapIndex, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    start_supervised!(BitmapQueries)
    start_supervised!({WorldCache, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    {:ok, snapshot} = await(fn -> BitmapIndex.snapshot() end, &match?({:ok, _}, &1))

    world =
      install_world([included, excluded], snapshot.dictionary_epoch, [
        %{
          relation_id: "invented-filtered-connection",
          source_id: included.uid,
          target_id: excluded.uid,
          evidence_class: "direct-physical"
        }
      ])

    {:ok, key} = TileKey.new(@version, 16, 0, 0)
    {:ok, tile} = WorldCache.fetch(key)

    assert Enum.sort(Enum.map(tile.glyphs, &{&1.kind, &1.id})) ==
             Enum.sort([{:device, included.uid}, {:device, excluded.uid}])

    response = TopologyTileController.manifest(binary_conn(scope), %{})
    assert response.status == 200
    manifest = Jason.decode!(response.resp_body)
    assert manifest["bitmap_membership_protocol"] == 1
    assert manifest["bitmap_membership_protocols"] == [1, 2]
    assert manifest["world_overlay_protocol"] == 1
    assert manifest["bitmap"]["ready"]
    assert manifest["bitmap"]["query"]["tag_keys"] == ["rack"]
    vlan = Enum.find(manifest["bitmap"]["query"]["facets"], &(&1["key"] == "vlan"))
    assert vlan["label"] == "Inventory VLAN"
    assert "eq" in vlan["operators"]

    :ok = WorldCache.clear_ordinals()
    response = TopologyTileController.manifest(binary_conn(scope), %{})
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["bitmap"]["reason"] == "membership_not_ready"
    :ok = WorldCache.install_ordinals(world, seal_mapping(world, [included, excluded], snapshot.dictionary_epoch))

    {:ok, _fence, socket} =
      UserSocket
      |> socket("synthetic-bitmap-viewer", %{current_scope: scope})
      |> subscribe_and_join(TopologyTileChannel, "topology:tiles", %{})

    params = %{
      "protocol" => 1,
      "layout_version" => @version,
      "query" => within_cohort(cohort, %{"facet" => "vlan", "value" => "20"}),
      "tiles" => [%{"z" => 16, "x" => 0, "y" => 0, "revision" => tile.revision}]
    }

    too_deep = Enum.reduce(1..9, %{"facet" => "vlan", "value" => "20"}, fn _, child -> %{"all" => [child]} end)

    for {expression, status, error} <- [
          {%{"facet" => "undeclared", "value" => "example"}, 422, "unsupported_query"},
          {%{"facet" => "vendor", "prefix" => "Example "}, 400, "invalid_query"},
          {too_deep, 413, "query_budget"}
        ] do
      query = TopologyQueryController.create(binary_conn(scope), %{"expression" => expression})

      selected =
        TopologyTileController.search(binary_conn(scope), %{
          "device_id" => included.uid,
          "query" => Jason.encode!(expression)
        })

      for response <- [query, selected] do
        assert response.status == status
        assert Jason.decode!(response.resp_body) == %{"error" => error}
        assert Plug.Conn.get_resp_header(response, "retry-after") == []
      end
    end

    ref = push(socket, "membership:watch", params)
    assert_reply ref, :ok, %{view_digest: digest, projection: %{mapped: 2, total: 2}}, 5_000
    assert_push "membership:frame", {:binary, frame}, 5_000
    {sequence, total, wire_digest, revision, mask, causal, availability, counts} = membership_rows(frame)
    assert total == 1
    assert wire_digest == digest
    assert revision == tile.revision
    assert causal == <<3, 3>>
    expected = for glyph <- tile.glyphs, do: if(glyph.id == included.uid, do: 1, else: 0)
    assert :binary.bin_to_list(mask) == expected
    assert for(<<count::little-32 <- counts>>, do: count) == expected
    assert :binary.bin_to_list(availability) == Enum.map(expected, &if(&1 == 1, do: 0, else: 2))
    assert {:ok, %{world: ^world}} = WorldCache.world()

    # No second frame is queued while the client owes an acknowledgement.
    send(socket.channel_pid, :tile_tick)
    refute_push "membership:frame", _frame, 100

    ref = push(socket, "membership:ack", %{"sequence" => Integer.to_string(sequence), "view_digest" => digest})
    assert_reply ref, :ok
    ref = push(socket, "membership:unwatch", %{})
    assert_reply ref, :ok
    send(socket.channel_pid, :tile_tick)
    refute_push "membership:frame", _frame, 100

    # Both native owners execute behind the real channel. The same edge is
    # excluded when only one endpoint matches, included when both match.
    assert length(tile.flow_edges) == 1

    for {query, expected} <- [{params["query"], 0}, {within_cohort(cohort, %{"all" => []}), 1}] do
      ref = push(socket, "membership:watch", %{params | "protocol" => 2, "query" => query})
      assert_reply ref, :ok, %{view_digest: edge_digest}, 5_000
      assert edge_digest != digest
      assert_push "membership:frame", {:binary, edge_frame}, 5_000
      assert <<"SRMO", 2, 0, _::binary>> = edge_frame
      footer_offset = byte_size(edge_frame) - 6
      assert <<_::binary-size(footer_offset), 1::little-16, ^expected::little-32>> = edge_frame
      ref = push(socket, "membership:unwatch", %{})
      assert_reply ref, :ok
    end

    stale = put_in(params, ["tiles"], [%{"z" => 16, "x" => 0, "y" => 0, "revision" => String.duplicate("f", 64)}])
    ref = push(socket, "membership:watch", stale)
    assert_reply ref, :error, %{reason: "source_changed"}, 5_000
    refute_push "membership:frame", _frame, 100

    # Geometry that blocks inside the admitted worker cannot outlive the build deadline.
    started = System.monotonic_time(:millisecond)
    :ok = :sys.suspend(WorldCache)

    try do
      assert {:error, :query_timeout} = BitmapView.build(scope, params, sequence + 1)
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert [] = Task.Supervisor.children(BitmapQueryTasks)
    after
      :sys.resume(WorldCache)
    end

    # The next tick delivers the replacement. An identical mapping keeps the built identity.
    ref = push(socket, "membership:watch", params)
    assert_reply ref, :ok, %{view_digest: rebuilt_digest}, 5_000
    assert_push "membership:frame", {:binary, rebuilt_frame}, 5_000
    built_identity = assert_delivered_identity(socket, scope)
    {rebuilt_sequence, _, _, _, _, _, _, _} = membership_rows(rebuilt_frame)

    ref =
      push(socket, "membership:ack", %{
        "sequence" => Integer.to_string(rebuilt_sequence),
        "view_digest" => rebuilt_digest
      })

    assert_reply ref, :ok

    fn ->
      {:ok, identical} = TopologyAtlas.new_ordinals(world, snapshot.dictionary_epoch)

      {:ok, _} =
        TopologyAtlas.apply_ordinals(world, identical, [
          {included.uid, FleetIdentity.device_ordinal(included.uid)},
          {excluded.uid, FleetIdentity.device_ordinal(excluded.uid)}
        ])

      {:ok, _} = TopologyAtlas.seal_ordinals(world, identical)
      assert :ok = WorldCache.install_ordinals(world, identical)
    end
    |> Task.async()
    |> Task.await(5_000)

    :erlang.garbage_collect(Process.whereis(WorldCache))
    send(socket.channel_pid, :tile_tick)
    refute_push "membership:frame", _identical, 200
    assert stream_identity(socket).assignment == built_identity.assignment

    {:ok, replacement} =
      await(fn -> TopologyAtlas.new_ordinals(world, snapshot.dictionary_epoch) end, &match?({:ok, _}, &1))

    {:ok, _} =
      TopologyAtlas.apply_ordinals(world, replacement, [{included.uid, FleetIdentity.device_ordinal(included.uid)}])

    {:ok, _} = TopologyAtlas.seal_ordinals(world, replacement)
    :ok = WorldCache.install_ordinals(world, replacement)
    send(socket.channel_pid, :tile_tick)
    assert_push "membership:frame", {:binary, _replaced_frame}, 5_000
    replaced = assert_delivered_identity(socket, scope)
    assert replaced.assignment != built_identity.assignment
    assert replaced.authority == built_identity.authority

    health = start_supervised!({WorldHealth, cache: WorldCache, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    {:ok, health_snapshot} = await(fn -> WorldHealth.snapshot(health) end, &match?({:ok, _}, &1))
    refute Map.has_key?(health_snapshot, :ordinals)

    start_supervised!(
      {WorldOverlay,
       name: WorldOverlay, cache: WorldCache, health: health, task_supervisor: tasks, pubsub: ServiceRadar.PubSub}
    )

    # An empty real tile exercises cache/read/encoding/HTTP without depending on
    # telemetry rows; source timestamps and binary negotiation still travel.
    {:ok, empty_key} = TileKey.new(@version, 16, 1, 1)
    {:ok, empty} = WorldCache.fetch(empty_key)
    overlay_params = %{"layout_version" => @version, "z" => "16", "x" => "1", "y" => "1", "revision" => empty.revision}
    response = TopologyTileController.overlay(binary_conn(scope), overlay_params)
    assert response.status == 200
    assert <<"SRTO", _::binary>> = response.resp_body
    assert [type] = Plug.Conn.get_resp_header(response, "content-type")
    assert String.starts_with?(type, "application/vnd.serviceradar.world-overlay")
    [etag] = Plug.Conn.get_resp_header(response, "etag")
    cached = scope |> binary_conn() |> Plug.Conn.put_req_header("if-none-match", etag)
    assert TopologyTileController.overlay(cached, overlay_params).status == 304

    # Each held worker completes against the current binding; the change made
    # before the channel processes that queued result must stop its delivery.
    # Every case runs on a freshly joined channel, whose first periodic refresh
    # is at least five seconds away and so cannot reorder ahead of the result.
    socket = rejoin(socket, scope)
    expired_ref = hold_completed_watch(socket, params)
    held = make_ref()
    Process.send_after(self(), {:deadline_elapsed, held}, 1_100)
    assert_receive {:deadline_elapsed, ^held}, 2_000
    :ok = :sys.resume(socket.channel_pid)
    assert_reply expired_ref, :error, %{reason: "query_timeout"}, 5_000
    refute_push "membership:frame", _expired_frame, 200

    # Seal the replacement before holding so DB lookups cannot spend the held
    # watch's one-second deadline; only its installation lands in that window.
    # Deliberate expiry is asserted separately above.
    remapping = seal_mapping(world, [included, excluded], snapshot.dictionary_epoch)
    socket = rejoin(socket, scope)
    remapped_ref = hold_completed_watch(socket, params)
    :ok = WorldCache.install_ordinals(world, remapping)
    :ok = :sys.resume(socket.channel_pid)
    assert_reply remapped_ref, :error, %{reason: "source_changed"}, 5_000
    refute_push "membership:frame", _remapped_frame, 200

    # A direct status write revokes read-time authority without the audit and
    # session-revocation side effects of :deactivate, which the owner test above
    # covers; those would otherwise spend the held watch's one-second deadline.
    socket = rejoin(socket, scope)
    revoked_ref = hold_completed_watch(socket, params)
    {1, _} = Repo.update_all(from(u in User, where: u.id == ^user.id), set: [status: :inactive])
    :ok = :sys.resume(socket.channel_pid)
    assert_reply revoked_ref, :error, %{reason: "forbidden"}, 5_000
    refute_push "membership:frame", _revoked_frame, 200
    assert TopologyTileController.overlay(cached, overlay_params).status == 403
    monitor = Process.monitor(socket.channel_pid)
    send(socket.channel_pid, :tile_tick)
    assert_push "topology_error", %{reason: "forbidden"}, 5_000
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 5_000
  end

  test "accepted membership follows the built revision and recomputes a named prefix tag without a new publication", %{
    cohort: cohort
  } do
    source = "synthetic-bitmap-" <> String.replace(Ecto.UUID.generate(), "-", "")
    on_exit(fn -> Store.clear(source) end)
    # The owner discovers sources through the registry; reuse an application-owned one.
    if !Process.whereis(Registry), do: start_supervised!(Registry)

    included =
      create("sr:bitmap-fence-#{System.unique_integer([:positive])}", %{
        region: cohort,
        is_available: true,
        ip: "192.0.2.10"
      })

    user =
      User
      |> Ash.Changeset.for_create(
        :create,
        %{email: "bitmap-fence-#{System.unique_integer([:positive])}@example.com", role: :viewer},
        actor: @actor
      )
      |> Ash.create!()

    scope = Scope.for_user(user)
    start_supervised!({Endpoint, []})
    tasks = start_supervised!({Task.Supervisor, name: TileWatchTasks, max_children: 8})
    Store.put_rows(source, [%{prefix: "198.51.100.0/24", tags: ["startup"]}])
    start_supervised!({BitmapIndex, name: BitmapIndex, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    start_supervised!(BitmapQueries)
    start_supervised!({WorldCache, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    {:ok, snapshot} = await(fn -> BitmapIndex.snapshot() end, &match?({:ok, _}, &1))
    await_catalog(source, ["startup"])
    _world = install_world([included], snapshot.dictionary_epoch)
    {:ok, key} = TileKey.new(@version, 16, 0, 0)
    {:ok, tile} = WorldCache.fetch(key)

    {:ok, _fence, socket} =
      UserSocket
      |> socket("synthetic-bitmap-fence", %{current_scope: scope})
      |> subscribe_and_join(TopologyTileChannel, "topology:tiles", %{})

    params = %{
      "protocol" => 1,
      "layout_version" => @version,
      "query" => within_cohort(cohort, %{"facet" => "region", "value" => cohort}),
      "tiles" => [%{"z" => 16, "x" => 0, "y" => 0, "revision" => tile.revision}]
    }

    {:ok, built} = await(fn -> BitmapIndex.snapshot() end, &quiet_index?/1)
    ref = push(socket, "membership:watch", params)
    assert_reply ref, :ok, %{view_digest: digest}, 5_000
    assert_push "membership:frame", {:binary, frame}, 5_000
    assert stream_identity(socket).index_revision == built.progress.index_revision
    {sequence, _total, _wire_digest, _revision, _mask, _causal, _availability, _counts} = membership_rows(frame)
    ref = push(socket, "membership:ack", %{"sequence" => Integer.to_string(sequence), "view_digest" => digest})
    assert_reply ref, :ok
    send(socket.channel_pid, :tile_tick)
    refute_push "membership:frame", _skipped, 200

    {:ok, before} = BitmapIndex.snapshot()

    assert {:ok, _} =
             Native.bitmap_index_publish(
               before.device,
               before.progress.index_revision,
               <<9::unsigned-64>>,
               [],
               true
             )

    {:ok, published} = BitmapIndex.snapshot()
    assert published.progress.index_revision == before.progress.index_revision + 1
    assert stream_identity(socket).index_revision == built.progress.index_revision
    holders = occupy_watch_tasks()

    try do
      send(socket.channel_pid, :tile_tick)
      refute_push "membership:frame", _reset, 200
    after
      Enum.each(holders, &Process.exit(&1, :kill))
    end

    await(fn -> Task.Supervisor.children(TileWatchTasks) end, &(&1 == []))

    # Waiting out the whole build deadline in admission is equally transient.
    # The retained binding is rechecked within its own budget, not the spent one.
    slots =
      for _ <- 1..8 do
        Task.async(fn ->
          BitmapQueryAdmission.run(fn -> Process.sleep(3_000) end, System.monotonic_time(:millisecond) + 5_000)
        end)
      end

    await(fn -> Task.Supervisor.children(BitmapQueryTasks) end, &(length(&1) == 8))
    send(socket.channel_pid, :tile_tick)
    refute_push "membership:frame", _expired_reset, 2_000
    Enum.each(slots, &assert({:ok, :ok} = Task.await(&1, 5_000)))
    assert stream_identity(socket).index_revision == built.progress.index_revision
    send(socket.channel_pid, :tile_tick)
    assert_push "membership:frame", {:binary, refreshed}, 5_000
    assert stream_identity(socket).index_revision == published.progress.index_revision
    {sequence, _total, _wire_digest, _revision, _mask, _causal, _availability, _counts} = membership_rows(refreshed)
    {:ok, during} = BitmapIndex.snapshot()
    assert during.progress.index_revision == published.progress.index_revision

    ref =
      push(socket, "membership:ack", %{
        "sequence" => Integer.to_string(sequence),
        "view_digest" => digest_of(refreshed)
      })

    assert_reply ref, :ok
    ref = push(socket, "membership:unwatch", %{})
    assert_reply ref, :ok

    expires_at = DateTime.shift(DateTime.utc_now(), second: 8)

    Store.put_rows(source, [
      %{prefix: "192.0.2.0/25", tags: ["office"], expires_at: expires_at}
    ])

    Phoenix.PubSub.broadcast(ServiceRadar.PubSub, Loader.pubsub_topic(), {:prefix_tags_snapshot_changed, %{}})
    await_catalog(source, ["office"])
    {:ok, %{version: version, trie: trie}} = Store.capture(source)
    assert {:ok, live_ranges} = PrefixNative.label_ranges(trie, "office", 8, 4_096, 1_000)
    assert byte_size(live_ranges) > 0

    prefix_params =
      Map.put(params, "query", %{
        "prefix_tag" => %{"source" => source, "label" => "office"}
      })

    {:ok, stable} = BitmapIndex.snapshot()
    ref = push(socket, "membership:watch", prefix_params)
    assert_reply ref, :ok, %{view_digest: prefix_digest}, 5_000
    assert_push "membership:frame", {:binary, prefix_frame}, 5_000

    {sequence, _total, _wire_digest, _revision, prefix_mask, _causal, _availability, _counts} =
      membership_rows(prefix_frame)

    assert prefix_mask == <<1>>
    ref = push(socket, "membership:ack", %{"sequence" => Integer.to_string(sequence), "view_digest" => prefix_digest})
    assert_reply ref, :ok
    # The channel's own periodic tick must not rebuild while the entry expires,
    # so its queued ticks run only once the task pool is saturated below.
    suspend_idle(socket)

    await(
      fn ->
        {:ok, %{trie: current}} = Store.capture(source)
        PrefixNative.label_ranges(current, "office", 8, 4_096, 1_000)
      end,
      &(&1 == {:ok, <<>>})
    )

    {:ok, %{version: ^version}} = Store.capture(source)
    {:ok, still} = BitmapIndex.snapshot()
    assert still.progress.index_revision == stable.progress.index_revision

    # The expired match must not survive a failed periodic rebuild as a
    # successful frame, even though the source version is unchanged.
    holders = occupy_watch_tasks()

    try do
      :ok = :sys.resume(socket.channel_pid)
      send(socket.channel_pid, :tile_tick)
      assert_push "membership:frame", {:binary, <<"SRMO", 1, 1, _::binary>>}, 5_000
      refute_push "membership:frame", _retained, 200
    after
      Enum.each(holders, &Process.exit(&1, :kill))
    end

    await(fn -> Task.Supervisor.children(TileWatchTasks) end, &(&1 == []))
    ref = push(socket, "membership:watch", prefix_params)
    assert_reply ref, :ok, _expired_binding, 5_000
    assert_push "membership:frame", {:binary, expired_frame}, 5_000

    {_sequence, _total, _wire_digest, _revision, expired_mask, _causal, _availability, _counts} =
      membership_rows(expired_frame)

    assert expired_mask == <<0>>
    {:ok, after_prefix} = BitmapIndex.snapshot()
    assert after_prefix.progress.index_revision == stable.progress.index_revision
  end

  test "tile HTTP classifies failures for a current viewer and refuses relayout without network management" do
    user =
      User
      |> Ash.Changeset.for_create(
        :create,
        %{email: "bitmap-tile-status-#{System.unique_integer([:positive])}@example.com", role: :viewer},
        actor: @actor
      )
      |> Ash.create!()

    scope = Scope.for_user(user)
    tile = fn version, z -> %{"layout_version" => version, "z" => Integer.to_string(z), "x" => "0", "y" => "0"} end
    overlay = fn revision -> Map.put(tile.(@version, 0), "revision", revision) end

    http = fn action, params ->
      conn = apply(TopologyTileController, action, [binary_conn(scope), params])
      {conn.status, Jason.decode!(conn.resp_body), Plug.Conn.get_resp_header(conn, "retry-after")}
    end

    assert {403, %{"error" => "forbidden"}, []} = http.(:relayout, %{})
    assert {400, %{"error" => "invalid_revision"}, []} = http.(:overlay, overlay.(String.duplicate("A", 64)))
    assert {503, %{"error" => "world_unavailable"}, ["1"]} = http.(:overlay, overlay.(String.duplicate("a", 64)))
    assert {503, %{"error" => "world_unavailable"}, ["1"]} = http.(:search, %{"device_id" => "synthetic"})

    start_supervised!({__MODULE__.Upstream, name: WorldOverlay, reply: {:error, :overlay_budget_exceeded}})
    assert {413, %{"error" => "topology_budget_exceeded"}, []} = http.(:overlay, overlay.(String.duplicate("b", 64)))
    stop_supervised!(__MODULE__.Upstream)

    start_supervised!({__MODULE__.Upstream, name: WorldCache, reply: {:error, :tile_budget_exceeded}})
    assert {413, %{"error" => "topology_budget_exceeded"}, []} = http.(:show, tile.(@version, 0))
    stop_supervised!(__MODULE__.Upstream)

    tasks = start_supervised!({Task.Supervisor, max_children: 4})
    start_supervised!({WorldCache, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    {:ok, builder} = TopologyAtlas.new_builder(@version, 16)

    :ok =
      TopologyAtlas.add_positions(builder, [
        %{
          device_id: "sr:bitmap-tile-status",
          label: "Synthetic device",
          x: 20,
          y: 20,
          min_zoom: 0,
          parent_id: nil,
          component_id: "invented-bitmap-component",
          component_z: 1,
          component_x: 0,
          component_y: 0,
          placement_depth: 4,
          active: true
        }
      ])

    {:ok, world} = TopologyAtlas.finish_world(builder)
    manifest = %{layout_version: @version, generation: 1, zmax: 0}

    prepared =
      Map.new(TileKey.low_zoom(manifest), fn key ->
        {:ok, built} = WorldTile.build(world, key)
        {key, built}
      end)

    :ok = WorldCache.install(world, manifest, prepared)

    assert {409, %{"error" => "layout_changed"}, []} =
             http.(:show, tile.("00000000-0000-4000-8000-000000000614", 3))

    assert {400, %{"error" => "invalid_tile"}, []} = http.(:show, tile.(@version, 3))
  end

  defp await_catalog(source, labels) do
    await(
      fn -> BitmapPrefixTags.page(%{"source" => source}, <<61::256>>, System.monotonic_time(:millisecond) + 1_000) end,
      &match?({:ok, %{labels: ^labels}}, &1)
    )
  end

  # Suspends the channel with no build running and no frame awaiting an ack. A
  # periodic tick that raced the caller's ack is delivered and acknowledged first.
  defp suspend_idle(socket) do
    :ok = :sys.suspend(socket.channel_pid)

    case :sys.get_state(socket.channel_pid).assigns.bitmap_stream do
      %{task: nil, awaiting: nil} ->
        :ok

      _busy ->
        :ok = :sys.resume(socket.channel_pid)
        assert_push "membership:frame", {:binary, frame}, 5_000
        {sequence, _total, digest, _revision, _mask, _causal, _availability, _counts} = membership_rows(frame)
        ref = push(socket, "membership:ack", %{"sequence" => Integer.to_string(sequence), "view_digest" => digest})
        assert_reply ref, :ok
        suspend_idle(socket)
    end
  end

  defp rejoin(socket, scope) do
    # Leaving a linked channel exits it with {:shutdown, :left}, which would
    # take the test down; only this intentional teardown is unlinked.
    Process.unlink(socket.channel_pid)
    monitor = Process.monitor(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, _pid, {:shutdown, :left}}, 5_000

    {:ok, _fence, socket} =
      UserSocket
      |> socket("synthetic-bitmap-viewer", %{current_scope: scope})
      |> subscribe_and_join(TopologyTileChannel, "topology:tiles", %{})

    socket
  end

  defp stream_task(socket), do: :sys.get_state(socket.channel_pid).assigns.bitmap_stream.task

  # Returns with the watch worker finished and its result queued behind a
  # suspended channel; the caller resumes the channel after changing state.
  defp hold_completed_watch(socket, params) do
    :ok = :sys.suspend(BitmapIndex)

    try do
      ref = push(socket, "membership:watch", params)
      %{pid: worker} = await(fn -> stream_task(socket) end, &is_map/1)
      worker_monitor = Process.monitor(worker)
      :ok = :sys.suspend(socket.channel_pid)
      :ok = :sys.resume(BitmapIndex)
      assert_receive {:DOWN, ^worker_monitor, :process, _pid, :normal}, 5_000
      ref
    after
      :sys.resume(BitmapIndex)
    end
  end

  defp stream_identity(socket) do
    %{assigns: %{bitmap_stream: %{identity: {:ok, identity}}}} = :sys.get_state(socket.channel_pid)
    identity
  end

  defp assert_delivered_identity(socket, scope) do
    identity = stream_identity(socket)
    {:ok, %{manifest: manifest, ordinals: %{info: info}}} = WorldCache.world()
    {:ok, snapshot} = BitmapIndex.snapshot()
    {:ok, authority} = BitmapAuthority.current(scope)

    assert identity.layout_version == manifest.layout_version
    assert identity.generation == manifest.generation
    assert identity.world_epoch == info.dictionary_epoch
    assert identity.assignment == info.assignment
    assert identity.dictionary_epoch == snapshot.dictionary_epoch
    assert identity.index_epoch == snapshot.index_epoch
    assert identity.index_revision == snapshot.progress.index_revision
    assert identity.authority == authority
    identity
  end

  defp quiet_index?({:ok, %{progress: %{pending_dirty: 0, reconciling: false, source_error: false}}}), do: true
  defp quiet_index?(_snapshot), do: false

  defp occupy_watch_tasks do
    holders =
      Enum.reduce_while(1..8, [], fn _, acc ->
        case Task.Supervisor.start_child(TileWatchTasks, fn ->
               Process.sleep(30_000)
             end) do
          {:ok, pid} -> {:cont, [pid | acc]}
          {:error, _} -> {:halt, acc}
        end
      end)

    assert {:error, _} =
             Task.Supervisor.start_child(TileWatchTasks, fn -> :ok end)

    holders
  end

  defp digest_of(frame) do
    {_sequence, _total, digest, _revision, _mask, _causal, _availability, _counts} = membership_rows(frame)
    digest
  end

  defp install_world(devices, epoch, relations \\ []) do
    {:ok, builder} = TopologyAtlas.new_builder(@version, 16)

    positions =
      devices
      |> Enum.with_index(1)
      |> Enum.map(fn {device, n} ->
        %{
          device_id: device.uid,
          label: "Synthetic device",
          x: n * 20,
          y: n * 20,
          min_zoom: 0,
          parent_id: nil,
          component_id: "invented-bitmap-component",
          component_z: 1,
          component_x: 0,
          component_y: 0,
          placement_depth: 4,
          active: true
        }
      end)

    :ok = TopologyAtlas.add_positions(builder, positions)
    :ok = TopologyAtlas.add_relations(builder, relations)
    {:ok, world} = TopologyAtlas.finish_world(builder)
    publish_layout(positions)
    manifest = %{layout_version: @version, generation: 1, zmax: 16}

    prepared =
      Map.new(TileKey.low_zoom(manifest), fn key ->
        {:ok, tile} = WorldTile.build(world, key)
        {key, tile}
      end)

    :ok = WorldCache.install(world, manifest, prepared)
    :ok = WorldCache.install_ordinals(world, seal_mapping(world, devices, epoch))
    world
  end

  # Device search authorizes against the persisted active layout before the
  # cached world, so the boxed sandbox publishes the same positions through the
  # real staging and activation owners. The sandbox rolls them back.
  defp publish_layout(positions) do
    previous =
      case World.active_manifest(:system) do
        {:ok, %{generation: generation}} -> generation
        {:error, :not_ready} -> 0
      end

    metadata = %{source_digest: "invented-bitmap-query", node_count: length(positions), relation_count: 0}
    :ok = World.stage_candidate(@version, metadata, positions, [])
    {:ok, %{layout_version: @version}} = World.activate_relayout(previous, @version)
  end

  defp seal_mapping(world, devices, epoch) do
    {:ok, mapping} = TopologyAtlas.new_ordinals(world, epoch)

    {:ok, _} =
      TopologyAtlas.apply_ordinals(world, mapping, Enum.map(devices, &{&1.uid, FleetIdentity.device_ordinal(&1.uid)}))

    {:ok, _} = TopologyAtlas.seal_ordinals(world, mapping)
    mapping
  end

  defp binary_conn(scope) do
    :get
    |> Plug.Test.conn("/")
    |> Plug.Conn.assign(:current_scope, scope)
    |> Plug.Conn.put_req_header("accept", "application/vnd.serviceradar.world-overlay")
  end

  # Decode only this test's one-tile SRMO wire contract independently of the
  # production encoder; expected membership comes from the invented inventory.
  defp membership_rows(frame) do
    <<"SRMO", 1, 0, 0::little-16, size::little-32, sequence::little-64, total::little-32, rest::binary>> = frame
    assert size == byte_size(frame)

    {fields, rest} =
      Enum.map_reduce(1..7, rest, fn _, <<length::little-16, tail::binary>> ->
        <<value::binary-size(length), tail::binary>> = tail
        {value, tail}
      end)

    <<count, rest::binary>> = rest
    rest = skip_prefix_sources(rest, count)

    <<1, 16, 0::little-32, 0::little-32, length::little-16, rest::binary>> = rest
    <<revision::binary-size(length), rows::little-16, rest::binary>> = rest
    <<mask::binary-size(rows), causal::binary-size(rows), availability::binary-size(rows), counts::binary>> = rest
    assert byte_size(counts) == rows * 4
    {sequence, total, Enum.at(fields, 4), revision, mask, causal, availability, counts}
  end

  defp skip_prefix_sources(rest, 0), do: rest

  defp skip_prefix_sources(<<length::little-16, tail::binary>>, count) when count in 1..32 do
    <<_source::binary-size(length), _version::little-64, tail::binary>> = tail
    skip_prefix_sources(tail, count - 1)
  end

  defp create(uid, attrs) do
    Device |> Ash.Changeset.for_create(:create, Map.put(attrs, :uid, uid), actor: @actor) |> Ash.create!()
  end

  defp within_cohort(cohort, expression), do: %{"all" => [%{"facet" => "region", "value" => cohort}, expression]}

  defp await(read, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000
    result = read.()

    cond do
      predicate.(result) ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("bitmap owner did not converge: #{inspect(result)}")

      true ->
        Process.sleep(25)
        await(read, predicate, deadline)
    end
  end
end

defmodule ServiceRadarWebNG.Topology.BitmapQueriesDBTest.Upstream do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :reply), name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(reply), do: {:ok, reply}

  @impl true
  def handle_call(_request, _from, reply), do: {:reply, reply, reply}
end
