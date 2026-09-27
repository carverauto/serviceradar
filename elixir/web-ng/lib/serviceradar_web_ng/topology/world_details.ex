defmodule ServiceRadarWebNG.Topology.WorldDetails do
  @moduledoc """
  Bounded picking reads over the accepted world and current authorized inventory.

  A request pins the publication seen by the picker and, for an aggregate, the
  encoded tile revision. Native selectors are obtained from the server cache;
  a client cannot invent aggregate membership. The supervised pool also bounds
  how many world handles can remain alive while inventory reads are pending.
  """

  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.AtlasLevel
  alias ServiceRadarWebNG.Topology.GodViewStream
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache

  @tasks ServiceRadarWebNG.Topology.WorldDetailTasks
  @timeout 10_000
  @max_bytes 262_144

  def fetch(scope, params), do: dispatch(:metadata, scope, params)

  @doc "Selects and enriches one bounded ELK scene for the schema-3 encoder."
  def scene(scope, params), do: dispatch(:scene, scope, params)

  defp dispatch(mode, scope, params) do
    with {:ok, request} <- request(mode, params) do
      owner = self()
      token = make_ref()

      case Task.Supervisor.start_child(@tasks, fn -> send(owner, {token, read(mode, scope, request)}) end) do
        {:ok, pid} -> await(pid, token)
        {:error, :max_children} -> {:error, :busy}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp await(pid, token) do
    ref = Process.monitor(pid)

    receive do
      {^token, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :unavailable}
    after
      @timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {:error, :unavailable}
    end
  end

  defp request(mode, %{"kind" => kind, "id" => id, "layout_version" => version, "generation" => generation} = params)
       when is_binary(id) and byte_size(id) > 0 do
    with {:ok, json} <- Jason.encode(params),
         true <- byte_size(json) <= @max_bytes,
         true <- allowed_kind?(mode, kind),
         {:ok, version} <- TileKey.layout_version(version),
         {:ok, generation} <- generation(generation),
         {:ok, tile} <- tile_request(kind, params),
         {:ok, cursor} <- cursor(Map.get(params, "cursor")) do
      {:ok, %{kind: kind, id: id, layout_version: version, generation: generation, tile: tile, cursor: cursor}}
    else
      _ -> {:error, :invalid_detail}
    end
  end

  defp request(_mode, _params), do: {:error, :invalid_detail}

  defp allowed_kind?(:metadata, kind), do: kind in ["device", "relation", "aggregate"]
  defp allowed_kind?(:scene, kind), do: kind in ["neighborhood", "component_members", "aggregate_members"]

  defp generation(value) when is_integer(value) and value > 0 and value <= 9_007_199_254_740_991, do: {:ok, value}

  defp generation(value) when is_binary(value) and byte_size(value) in 1..16 do
    case Integer.parse(value) do
      {number, ""} -> if Integer.to_string(number) == value, do: generation(number), else: {:error, :invalid_generation}
      _ -> {:error, :invalid_generation}
    end
  end

  defp generation(_value), do: {:error, :invalid_generation}

  defp tile_request(kind, _params) when kind in ["device", "relation", "neighborhood", "component_members"],
    do: {:ok, nil}

  defp tile_request(kind, %{"tile_revision" => revision} = params) when kind in ["aggregate", "aggregate_members"] do
    with {:ok, revision} <- TileKey.content_revision(revision),
         {:ok, key} <- TileKey.parse(params) do
      {:ok, %{key: key, revision: revision}}
    end
  end

  defp tile_request(_kind, _params), do: {:error, :invalid_tile}

  defp cursor(nil), do: {:ok, nil}

  defp cursor(encoded) when is_binary(encoded) and byte_size(encoded) <= 512 do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"world_revision" => world, "scope_revision" => scope, "node_page" => node, "edge_page" => edge}} <-
           Jason.decode(json),
         {:ok, world} <- TileKey.content_revision(world),
         {:ok, scope} <- TileKey.content_revision(scope),
         true <- is_integer(node) and node in 0..4_294_967_295,
         true <- is_integer(edge) and edge in 0..4_294_967_295 do
      {:ok, %{world_revision: world, scope_revision: scope, node_page: node, edge_page: edge}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor(_encoded), do: {:error, :invalid_cursor}

  defp encode_cursor(nil), do: nil
  defp encode_cursor(cursor), do: cursor |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp read(mode, scope, request) do
    with {:ok, %{world: world, manifest: manifest}} <- WorldCache.world(),
         :ok <- matches_publication(request, manifest),
         {:ok, details} <- select(mode, scope, world, request),
         {:ok, current} <- WorldCache.manifest(),
         :ok <- matches_publication(request, current) do
      finish(mode, request, details)
    else
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp finish(:metadata, request, details) do
    bounded(%{
      layout_version: request.layout_version,
      generation: request.generation,
      kind: request.kind,
      id: request.id,
      details: details
    })
  end

  defp finish(:scene, _request, level), do: {:ok, level}

  defp select(:metadata, scope, world, %{kind: "device", id: id}) do
    with {:ok, position} <- TopologyAtlas.search(world, id),
         {:ok, devices} <- GodViewStream.fetch_devices_for_scope(scope, [id]),
         {:ok, level} <- enrich([position], devices) do
      [node] = level.nodes

      {:ok,
       %{
         device: node,
         world_position: Map.take(position, [:x, :y, :min_zoom]),
         scene: %{kind: "neighborhood", id: id},
         deferred_details: level.deferred_details
       }}
    end
  end

  defp select(:metadata, scope, world, %{kind: "relation", id: id}) do
    with {:ok, selected} <- TopologyAtlas.relation(world, id),
         {:ok, devices} <-
           GodViewStream.fetch_devices_for_scope(scope, Enum.uniq(Enum.map(selected.nodes, & &1.device_id))),
         {:ok, level} <- enrich(selected.nodes, devices) do
      {:ok,
       %{
         relation: Map.delete(selected.relation, :active),
         endpoints: level.nodes,
         scene: %{kind: "neighborhood", id: selected.relation.source_id},
         deferred_details: level.deferred_details
       }}
    end
  end

  defp select(:metadata, _scope, world, %{kind: "aggregate", id: id, tile: expected} = request) do
    with {:ok, aggregate} <- aggregate(world, request),
         {:ok, info} <- TopologyAtlas.aggregate_info(aggregate) do
      {:ok,
       %{
         members: info.member_count,
         tile_revision: expected.revision,
         scene: %{
           kind: "aggregate_members",
           id: id,
           z: expected.key.z,
           x: expected.key.x,
           y: expected.key.y,
           tile_revision: expected.revision
         }
       }}
    end
  end

  defp select(:scene, scope, world, request) do
    with {:ok, native_scope} <- scene_scope(world, request),
         {:ok, page} <- TopologyAtlas.detail(world, native_scope, request.cursor),
         {:ok, devices} <- GodViewStream.fetch_devices_for_scope(scope, Enum.map(page.nodes, & &1.device_id)) do
      page |> level(request) |> AtlasLevel.enrich(Map.new(devices, &{&1.uid, &1}))
    end
  end

  defp scene_scope(_world, %{kind: "neighborhood", id: id}), do: {:ok, {:neighborhood, id}}
  defp scene_scope(_world, %{kind: "component_members", id: id}), do: {:ok, {:component_members, id}}

  defp scene_scope(world, %{kind: "aggregate_members"} = request) do
    with {:ok, selection} <- aggregate(world, request), do: {:ok, {:aggregate_members, selection}}
  end

  defp aggregate(world, %{id: id, tile: expected, generation: generation}) do
    with {:ok, tile} <- WorldCache.fetch(expected.key),
         true <- tile.generation == generation and tile.revision == expected.revision,
         {:ok, aggregate} <- TopologyAtlas.aggregate_selection(world, tile.selection, id) do
      {:ok, aggregate}
    else
      false -> {:error, :stale_revision}
      {:error, _reason} = error -> error
    end
  end

  defp level(page, request) do
    nodes = Enum.map(page.nodes, &%{id: &1.device_id, label: &1.label, aggregate: false})
    identities = nodes |> Enum.map(& &1.id) |> List.to_tuple()

    edges =
      Enum.map(page.relations, fn edge ->
        edge
        |> Map.take([:id, :evidence_class, :role])
        |> Map.merge(%{source: elem(identities, edge.source), target: elem(identities, edge.target)})
      end)

    %{
      level_id: scene_id(request),
      parent_level_id: if(request.cursor, do: scene_id(%{request | cursor: nil})),
      layout_version: request.layout_version,
      generation: request.generation,
      canonical_revision: request.generation,
      structure_revision: {Enum.map(nodes, & &1.id), edges},
      kind: request.kind,
      nodes: nodes,
      edges: edges,
      next_cursor: encode_cursor(page.next_cursor),
      counts: %{
        members: page.total_members,
        selected_relations: page.selected_relations,
        incident_relations: page.incident_relations,
        visible_nodes: length(nodes),
        visible_relations: length(page.relations)
      },
      budgets: %{nodes: 128, edges: 256, members: if(request.kind == "neighborhood", do: 127, else: 64)}
    }
  end

  defp scene_id(request) do
    digest =
      {request.layout_version, request.kind, request.id, request.tile, request.cursor}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "world-detail:" <> digest
  end

  defp enrich(positions, devices) do
    level = %{
      nodes: Enum.map(positions, &%{id: &1.device_id, label: &1.label, aggregate: false}),
      structure_revision: Enum.map(positions, & &1.device_id),
      budgets: %{nodes: length(positions), edges: 0}
    }

    AtlasLevel.enrich(level, Map.new(devices, &{&1.uid, &1}))
  end

  defp matches_publication(%{layout_version: version, generation: generation}, %{
         layout_version: version,
         generation: generation
       }), do: :ok

  defp matches_publication(%{layout_version: version}, %{layout_version: version}), do: {:error, :stale_revision}
  defp matches_publication(_request, _manifest), do: {:error, :layout_changed}

  defp bounded(content) do
    payload = Jason.encode!(content)

    if byte_size(payload) <= @max_bytes do
      revision = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)
      {:ok, %{content: content, payload: payload, revision: revision}}
    else
      {:error, :payload_too_large}
    end
  end
end
