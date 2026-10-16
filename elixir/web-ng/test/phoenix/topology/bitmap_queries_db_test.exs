defmodule ServiceRadarWebNG.Topology.BitmapQueriesDBTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.FleetIdentity
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapSelection
  alias ServiceRadarWebNG.Topology.BitmapSource
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNGWeb.Endpoint

  @moduletag :topology_atlas_db
  @actor SystemActor.system(:bitmap_query_database_test)

  setup do
    :ok = Sandbox.checkout(Repo)
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
