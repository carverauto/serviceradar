defmodule ServiceRadarWebNG.Topology.BitmapQueriesDBTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ChannelTest

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.FleetIdentity
  alias ServiceRadar.Repo
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapSelection
  alias ServiceRadarWebNG.Topology.BitmapSource
  alias ServiceRadarWebNG.Topology.BitmapView
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldHealth
  alias ServiceRadarWebNG.Topology.WorldOverlay
  alias ServiceRadarWebNG.Topology.WorldTile
  alias ServiceRadarWebNGWeb.Endpoint
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
        [:god_view_enabled, :topology_bitmap_enabled, :bitmap_tag_keys],
        &{&1, Application.fetch_env(:serviceradar_web_ng, &1)}
      )

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)
    Application.put_env(:serviceradar_web_ng, :topology_bitmap_enabled, true)
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
    :ok
  end

  test "typed source projects canonical fields and configured scalar tags without retaining arbitrary device payloads" do
    device =
      create("sr:bitmap-source", %{
        vendor_name: " ExampleVendor ",
        region: "example-west",
        vlan_uid: "example-vlan",
        type_id: 10,
        os: %{"name" => "ExampleOS", "version" => "2", "unused" => String.duplicate("z", 100_000)},
        tags: %{"rack" => "example-rack", "unconfigured" => String.duplicate("q", 100_000)},
        is_available: false
      })

    ordinal = FleetIdentity.device_ordinal(device.uid)
    assert {:ok, facets} = BitmapSource.supported_facets(:device)
    assert {:ok, [{^ordinal, true, values}]} = BitmapSource.fetch([ordinal], facets)

    assert Map.new(values) == %{
             "vendor" => "ExampleVendor",
             "region" => "example-west",
             "vlan" => "example-vlan",
             "device_class" => "10",
             "os_name" => "ExampleOS",
             "os_version" => "2",
             "availability" => "unavailable",
             "tag:rack" => "example-rack"
           }

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
  end

  test "real owner repairs unhinted writes, pages current membership, and rechecks revoked authority before delivery" do
    first = create("sr:bitmap-first", %{vendor_name: "example-a"})
    removed = create("sr:bitmap-removed", %{vendor_name: "example-a"})
    excluded = create("sr:bitmap-excluded", %{vendor_name: "example-b"})

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

    expression = %{"facet" => "vendor", "value" => "example-a"}
    params = %{"expression" => expression, "limit" => 1, "facets" => [%{"facet" => "vendor", "value" => "example-a"}]}
    first_ordinal = FleetIdentity.device_ordinal(first.uid)

    assert {:ok, %{ordinals: [^first_ordinal], total: 2, cursor: cursor, facets: [%{count: 2}]}} =
             BitmapQueries.run(scope, params)

    assert {:error, :not_found} =
             BitmapSelection.authorize(scope, %{"query" => Jason.encode!(expression)}, [excluded.uid])

    # This raw writer emits no PubSub event. A complete keyset pass must repair
    # membership without treating modified_time or allocation order as a commit watermark.
    Repo.update_all(from(d in Device, where: d.uid == ^removed.uid), set: [vendor_name: "example-b"])
    added = create("sr:bitmap-added", %{vendor_name: "example-a"})
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

    {:ok, snapshot} = BitmapIndex.snapshot()
    Application.put_env(:serviceradar_web_ng, :topology_bitmap_enabled, false)
    assert {:error, :bitmap_disabled} = BitmapIndex.snapshot()
    assert {:ok, %{ready: false, cardinality: 0}} = Native.bitmap_index_status(snapshot.device)
  end

  test "real channel projects admitted Arrow rows and binary HTTP preserves authority before cached delivery" do
    included = create("sr:bitmap-map-included", %{vlan_uid: "20", is_available: true})
    excluded = create("sr:bitmap-map-excluded", %{vlan_uid: "30", is_available: false})

    user =
      User
      |> Ash.Changeset.for_create(:create, %{email: "bitmap-map-viewer@example.com", role: :viewer}, actor: @actor)
      |> Ash.create!()

    scope = Scope.for_user(user)
    start_supervised!({Endpoint, []})
    tasks = start_supervised!({Task.Supervisor, name: ServiceRadarWebNG.Topology.TileWatchTasks, max_children: 8})
    start_supervised!({BitmapIndex, name: BitmapIndex, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    start_supervised!(BitmapQueries)
    start_supervised!({WorldCache, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    {:ok, snapshot} = await(fn -> BitmapIndex.snapshot() end, &match?({:ok, _}, &1))
    world = install_world([included, excluded], snapshot.dictionary_epoch)
    {:ok, key} = TileKey.new(@version, 16, 0, 0)
    {:ok, tile} = WorldCache.fetch(key)

    assert Enum.sort(Enum.map(tile.glyphs, &{&1.kind, &1.id})) ==
             Enum.sort([{:device, included.uid}, {:device, excluded.uid}])

    response = TopologyTileController.manifest(binary_conn(scope), %{})
    assert response.status == 200
    manifest = Jason.decode!(response.resp_body)
    assert manifest["bitmap_membership_protocol"] == 1
    assert manifest["world_overlay_protocol"] == 1
    assert manifest["bitmap"]["ready"]
    assert manifest["bitmap"]["query"]["tag_keys"] == ["rack"]
    vlan = Enum.find(manifest["bitmap"]["query"]["facets"], &(&1["key"] == "vlan"))
    assert vlan["label"] == "Inventory VLAN"
    assert "eq" in vlan["operators"]

    {:ok, %{ordinals: projection}} = WorldCache.world()
    :ok = WorldCache.clear_ordinals()
    response = TopologyTileController.manifest(binary_conn(scope), %{})
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["bitmap"]["reason"] == "membership_not_ready"
    :ok = WorldCache.install_ordinals(world, projection.mapping)

    {:ok, _fence, socket} =
      UserSocket
      |> socket("synthetic-bitmap-viewer", %{current_scope: scope})
      |> subscribe_and_join(TopologyTileChannel, "topology:tiles", %{})

    params = %{
      "protocol" => 1,
      "layout_version" => @version,
      "query" => %{"facet" => "vlan", "value" => "20"},
      "tiles" => [%{"z" => 16, "x" => 0, "y" => 0, "revision" => tile.revision}]
    }

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

    stale = put_in(params, ["tiles"], [%{"z" => 16, "x" => 0, "y" => 0, "revision" => String.duplicate("f", 64)}])
    ref = push(socket, "membership:watch", stale)
    assert_reply ref, :error, %{reason: "source_changed"}, 5_000
    refute_push "membership:frame", _frame, 100

    # A completed response can wait in the channel mailbox while the optional
    # canonical mapping changes without a new geometry or dictionary epoch.
    {:ok, pending} = BitmapView.build(scope, params, sequence + 1)
    assert :ok = BitmapView.confirm_delivery(scope, pending)
    {:ok, replacement} = TopologyAtlas.new_ordinals(world, snapshot.dictionary_epoch)

    {:ok, _} =
      TopologyAtlas.apply_ordinals(world, replacement, [
        {included.uid, FleetIdentity.device_ordinal(included.uid)},
        {excluded.uid, FleetIdentity.device_ordinal(excluded.uid)}
      ])

    {:ok, _} = TopologyAtlas.seal_ordinals(world, replacement)
    :ok = WorldCache.install_ordinals(world, replacement)
    assert {:error, :source_changed} = BitmapView.confirm_delivery(scope, pending)

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

    user |> Ash.Changeset.for_update(:deactivate, %{}, actor: @actor) |> Ash.update!()
    assert TopologyTileController.overlay(cached, overlay_params).status == 403
    monitor = Process.monitor(socket.channel_pid)
    send(socket.channel_pid, :tile_tick)
    assert_push "topology_error", %{reason: "forbidden"}, 5_000
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 5_000
  end

  defp install_world(devices, epoch) do
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
    {:ok, world} = TopologyAtlas.finish_world(builder)
    manifest = %{layout_version: @version, generation: 1, zmax: 16}

    prepared =
      Map.new(TileKey.low_zoom(manifest), fn key ->
        {:ok, tile} = WorldTile.build(world, key)
        {key, tile}
      end)

    :ok = WorldCache.install(world, manifest, prepared)
    {:ok, mapping} = TopologyAtlas.new_ordinals(world, epoch)

    {:ok, _} =
      TopologyAtlas.apply_ordinals(world, mapping, Enum.map(devices, &{&1.uid, FleetIdentity.device_ordinal(&1.uid)}))

    {:ok, _} = TopologyAtlas.seal_ordinals(world, mapping)
    :ok = WorldCache.install_ordinals(world, mapping)
    world
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
