defmodule ServiceRadarWebNGWeb.Topology.AtlasChannelDBTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Topology.Atlas
  alias ServiceRadarWebNG.Topology.AtlasReader
  alias ServiceRadarWebNG.Topology.AtlasStore
  alias ServiceRadarWebNGWeb.TopologyChannel
  alias ServiceRadarWebNGWeb.TopologySnapshotController

  @moduletag :topology_atlas_db
  @topic "topology:god_view"

  setup do
    :ok = Sandbox.checkout(Repo)
    previous_flag = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    if is_nil(Process.whereis(AtlasStore)) do
      start_supervised!({AtlasStore, name: AtlasStore})
    else
      :ok = AtlasStore.publish(nil)
    end

    on_exit(fn ->
      if is_nil(previous_flag),
        do: Application.delete_env(:serviceradar_web_ng, :god_view_enabled),
        else: Application.put_env(:serviceradar_web_ng, :god_view_enabled, previous_flag)
    end)

    system_scope = Scope.for_user(SystemActor.system(:topology_atlas_test))
    unique = System.unique_integer([:positive])
    permissions = ["analytics.view", "devices.view"]

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create_system,
        %{
          system_name: "atlas-test-#{unique}",
          name: "Atlas test observer",
          permissions: permissions
        },
        scope: system_scope
      )
      |> Ash.create!()

    user =
      User
      |> Ash.Changeset.for_create(
        :create,
        %{
          email: "atlas-observer-#{unique}@example.com",
          display_name: "Atlas observer",
          role: :viewer,
          role_profile_id: profile.id
        },
        scope: system_scope
      )
      |> Ash.create!()

    scope =
      Scope.for_user(user,
        permissions: MapSet.new(permissions),
        identity_claims: %{"groups" => ["SITE01-observers"]}
      )

    socket = %Phoenix.Socket{
      assigns: %{current_user: user, current_scope: scope},
      joined: true,
      serializer: Phoenix.Socket.V2.JSONSerializer,
      topic: @topic,
      transport_pid: self()
    }

    %{scope: scope, socket: socket, profile: profile, system_scope: system_scope}
  end

  test "watch opt-in sends targeted invalidations and no binary snapshots", %{socket: socket} do
    publish_nodes(5, node_budget: 4, label_budget: 4)
    assert {:error, %{reason: "invalid_mode"}} = TopologyChannel.join(@topic, %{"mode" => "unknown"}, socket)

    assert {:error, %{reason: "invalid_levels"}} =
             TopologyChannel.join(@topic, %{"mode" => "levels", "level_ids" => List.duplicate("global", 65)}, socket)

    refute_receive :tick

    assert {:ok, socket} =
             TopologyChannel.join(
               @topic,
               %{
                 "mode" => "levels",
                 "level_ids" => ["global:00:00", "global:1:0"]
               },
               socket
             )

    assert socket.assigns.stream_mode == :levels
    assert socket.assigns.current_scope.identity_claims == %{"groups" => ["SITE01-observers"]}
    assert_receive :tick

    assert {:noreply, socket} = TopologyChannel.handle_info(:tick, socket)
    first = receive_push("topology_invalidated")
    assert first["reset"] == true
    assert first["affected_level_ids"] == ["global", "global:1:0"]
    revisions = socket.assigns.last_level_revisions
    assert revisions.levels["global:1:0"]
    assert {:noreply, socket} = TopologyChannel.handle_info(:tick, socket)
    refute_receive {:socket_push, _, _}

    publish_nodes(1)
    assert {:noreply, socket} = TopologyChannel.handle_info(:tick, socket)
    payload = receive_push("topology_invalidated")
    assert payload["affected_level_ids"] == ["global", "global:1:0"]
    assert payload["levels"]["global:1:0"] == nil
    assert payload["previous_canonical_revision"] == revisions.canonical_revision
    assert payload["reset"] == false

    assert {:reply, {:error, %{reason: "unsupported_event"}}, _socket} =
             TopologyChannel.handle_in("cluster:collapse_all", %{}, socket)

    refute_receive {:socket_push, _, _}
  end

  test "a watch accepted before publication remains metadata-only through recovery", %{socket: socket} do
    assert {:ok, socket} = TopologyChannel.join(@topic, %{}, socket)
    assert socket.assigns.stream_mode == :legacy
    unavailable = revisions(socket.assigns.current_scope, %{})
    assert unavailable.status == 503
    assert Plug.Conn.get_resp_header(unavailable, "retry-after") == ["1"]
    assert Jason.decode!(unavailable.resp_body) == %{"error" => "atlas_not_ready"}

    assert_receive :tick

    assert {:reply, {:error, %{reason: "atlas_not_ready"}}, socket} =
             TopologyChannel.handle_in("levels:watch", %{}, socket)

    assert socket.assigns.stream_mode == :levels

    assert {:noreply, socket} = TopologyChannel.handle_info(:tick, socket)
    assert receive_push("topology_error") == %{"reason" => "atlas_not_ready"}
    publish_nodes(1)
    assert {:noreply, _socket} = TopologyChannel.handle_info(:tick, socket)
    payload = receive_push("topology_invalidated")
    assert payload["reset"] == true
    assert payload["previous_canonical_revision"] == nil
    assert payload["affected_level_ids"] == ["global"]
    refute_receive {:socket_push, _, _}
  end

  test "persisted permission revocation closes cached joins, events and tick delivery", context do
    publish_nodes(1)
    assert {:ok, socket} = TopologyChannel.join(@topic, %{}, context.socket)
    assert_receive :tick
    assert {:reply, {:ok, _revisions}, socket} = TopologyChannel.handle_in("levels:watch", %{}, socket)

    context.profile
    |> Ash.Changeset.for_update(:update_system, %{permissions: []}, scope: context.system_scope)
    |> Ash.update!()

    assert MapSet.member?(socket.assigns.current_scope.permissions, "analytics.view")
    denied = revisions(context.scope, %{"level_ids" => "invalid"})
    assert denied.status == 403
    assert Jason.decode!(denied.resp_body) == %{"error" => "forbidden"}
    assert Plug.Conn.get_resp_header(denied, "cache-control") == ["no-store"]

    assert {:error, %{reason: "forbidden"}} = TopologyChannel.join(@topic, %{}, socket)

    for event <- ["levels:watch", "cluster:set_expanded", "cluster:collapse_all"] do
      assert {:reply, {:error, %{reason: "forbidden"}}, ^socket} =
               TopologyChannel.handle_in(event, %{}, socket)
    end

    assert {:stop, :normal, ^socket} = TopologyChannel.handle_info(:tick, socket)
    assert receive_push("topology_error") == %{"reason" => "forbidden"}
    refute_receive {:socket_push, _, _}
  end

  test "legacy join denies a role granted analytics.view but not devices.view", context do
    context.profile
    |> Ash.Changeset.for_update(:update_system, %{permissions: ["analytics.view"]}, scope: context.system_scope)
    |> Ash.update!()

    assert {:error, %{reason: "forbidden"}} = TopologyChannel.join(@topic, %{}, context.socket)
  end

  test "scoped inventory changes invalidate final revisions without replacing the canonical graph", context do
    device =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "atlas-host01.example.com",
          hostname: "host01.example.com",
          name: "Atlas inventory host",
          ip: "192.0.2.10",
          type_id: 0,
          is_available: true
        },
        scope: context.system_scope
      )
      |> Ash.create!()

    assert {:ok, index} = Atlas.build([%{id: device.uid}], [])
    :ok = AtlasStore.publish(index)
    assert {:ok, %{nodes: [%{child_level_id: child}]}} = AtlasReader.fetch(context.scope)
    assert {:ok, original} = AtlasReader.fetch(context.scope, child)
    assert [%{inventory_present: true, label: "Atlas inventory host", details: %{ip: "192.0.2.10"}}] = original.nodes
    assert {:ok, ^original} = AtlasReader.fetch(context.scope, child, original.revision)

    device
    |> Ash.Changeset.for_update(:update, %{name: "Atlas renamed host"}, scope: context.system_scope)
    |> Ash.update!()

    assert {:ok, changed} = AtlasReader.fetch(context.scope, child)
    assert [%{label: "Atlas renamed host"}] = changed.nodes
    assert changed.canonical_revision == original.canonical_revision
    assert changed.structure_revision == original.structure_revision
    refute changed.revision == original.revision
    assert {:error, {:stale_revision, current}} = AtlasReader.fetch(context.scope, child, original.revision)
    assert current == changed.revision
    assert {:ok, %{levels: %{^child => final}}} = AtlasReader.revisions(context.scope, [child])
    assert final.revision == changed.revision
    assert final.structure_revision == changed.structure_revision

    invalid = revisions(context.scope, %{"level_ids" => List.duplicate("global", 65)})
    assert invalid.status == 400
    assert Jason.decode!(invalid.resp_body) == %{"error" => "invalid_levels"}
    conn = revisions(context.scope, %{"level_ids" => [child, "global:00:00", "global", "global:9:0"]})
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    metadata = Jason.decode!(conn.resp_body)
    assert metadata["canonical_revision"] == changed.canonical_revision

    assert metadata["levels"][child] == %{
             "revision" => changed.revision,
             "structure_revision" => changed.structure_revision
           }

    assert metadata["levels"]["global:9:0"] == nil
    assert metadata["levels"] |> Map.keys() |> Enum.sort() == Enum.sort([child, "global", "global:9:0"])

    context.profile
    |> Ash.Changeset.for_update(:update_system, %{permissions: ["analytics.view"]}, scope: context.system_scope)
    |> Ash.update!()

    assert revisions(context.scope, %{}).status == 200
    forbidden = revisions(context.scope, %{"level_ids" => [child]})
    assert forbidden.status == 403
    assert Jason.decode!(forbidden.resp_body) == %{"error" => "forbidden"}
    assert {:ok, current_scope} = RBAC.authorize_current(context.scope, ["analytics.view"])
    refute MapSet.member?(current_scope.permissions, "devices.view")
    assert {:error, :forbidden} = AtlasReader.fetch(current_scope, child)
  end

  defp publish_nodes(count, opts \\ []) do
    nodes = Enum.map(1..count, &%{id: "host#{&1}.example.com"})
    {:ok, index} = Atlas.build(nodes, [], opts)
    :ok = AtlasStore.publish(index)
  end

  defp revisions(scope, params) do
    :get
    |> Plug.Test.conn("/topology/snapshot/revisions")
    |> Plug.Conn.assign(:current_scope, scope)
    |> TopologySnapshotController.revisions(params)
  end

  defp receive_push(event) do
    assert_receive {:socket_push, :text, encoded}
    assert [nil, nil, @topic, ^event, payload] = Jason.decode!(IO.iodata_to_binary(encoded))
    payload
  end
end
