defmodule ServiceRadarWebNG.Topology.AtlasTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.Atlas

  @moduletag :db_free

  test "every canonical member and relation remains reachable across all bounded semantic levels" do
    {nodes, edges} = small_graph()

    assert {:ok, index} =
             Atlas.build(nodes, edges,
               node_budget: 6,
               label_budget: 4,
               edge_budget: 2,
               member_page_size: 2
             )

    levels = walk(index)

    assert MapSet.new(levels, & &1.kind) == MapSet.new(~w(global component neighborhood members))
    assert Enum.any?(levels, &(&1.next_level_id != nil))

    reached_nodes =
      levels
      |> Enum.flat_map(& &1.nodes)
      |> Enum.reject(&Map.get(&1, :aggregate, false))
      |> MapSet.new(& &1.id)

    reached_relations =
      levels
      |> Enum.flat_map(& &1.edges)
      |> Enum.reject(&Map.get(&1, :aggregate, false))
      |> MapSet.new(& &1.relation_id)

    assert reached_nodes == MapSet.new(nodes, & &1.id)
    assert reached_relations == MapSet.new(edges, & &1.relation_id)

    for level <- levels do
      assert_bounded(level)
      assert {:ok, ^level} = Atlas.fetch(index, level.level_id, level.revision)

      if level.parent_level_id do
        assert {:ok, _parent} = Atlas.fetch(index, level.parent_level_id)
      end
    end
  end

  test "input order and telemetry preserve navigation and geometry while changed levels get new revisions" do
    {nodes, edges} = small_graph()
    assert {:ok, original} = Atlas.build(nodes, edges)
    assert {:ok, reversed} = Atlas.build(Enum.reverse(nodes), Enum.reverse(edges))
    original_levels = Map.new(walk(original), &{&1.level_id, &1})
    reversed_levels = Map.new(walk(reversed), &{&1.level_id, &1})
    assert original_levels == reversed_levels
    assert original.revision == reversed.revision

    [changed_edge | rest] = edges
    assert {:ok, updated} = Atlas.build(nodes, [Map.put(changed_edge, :flow_pps, 99) | rest])
    refute original.revision == updated.revision
    updated_levels = Map.new(walk(updated), &{&1.level_id, &1})
    assert original_levels |> Map.keys() |> Enum.sort() == updated_levels |> Map.keys() |> Enum.sort()

    for {id, before} <- original_levels do
      after_update = Map.fetch!(updated_levels, id)
      assert before.structure_revision == after_update.structure_revision
      assert before.parent_level_id == after_update.parent_level_id
    end

    affected =
      Enum.filter(original_levels, fn {id, level} ->
        level.revision != updated_levels[id].revision
      end)

    unaffected =
      Enum.reject(original_levels, fn {id, level} ->
        level.revision != updated_levels[id].revision
      end)

    assert affected != []
    assert unaffected != []

    for {id, level} <- affected do
      current = updated_levels[id].revision
      assert {:error, {:stale_revision, ^current}} = Atlas.fetch(updated, id, level.revision)
    end

    for {id, level} <- unaffected do
      assert {:ok, ^level} = Atlas.fetch(updated, id, level.revision)
    end
  end

  test "structural changes invalidate only levels whose content or navigation changes" do
    nodes = Enum.map(1..4, &device_node/1)
    edges = [edge(1, 2, "first"), edge(3, 4, "second")]
    assert {:ok, original} = Atlas.build(nodes, edges)
    assert {:ok, global} = Atlas.fetch(original)
    [first, second] = global.nodes
    assert {:ok, first_level} = Atlas.fetch(original, first.child_level_id)
    assert {:ok, second_level} = Atlas.fetch(original, second.child_level_id)

    changes = [
      {nodes,
       [
         %{hd(edges) | relation_id: "replacement", evidence_class: "direct-logical"},
         List.last(edges)
       ]},
      {nodes, [Map.put(hd(edges), :metadata, %{"connectivity_forest_bridge" => true}), List.last(edges)]},
      {[Map.put(hd(nodes), :details, %{"type" => "gateway"}) | tl(nodes)], edges},
      {[Map.put(hd(nodes), :details, %{"cluster_kind" => "endpoint-anchor"}) | tl(nodes)], edges}
    ]

    for {changed_nodes, changed_edges} <- changes do
      assert {:ok, updated} = Atlas.build(changed_nodes, changed_edges)
      assert {:ok, changed_level} = Atlas.fetch(updated, first.child_level_id)
      refute first_level.revision == changed_level.revision
      refute first_level.structure_revision == changed_level.structure_revision

      assert {:ok, ^second_level} =
               Atlas.fetch(updated, second.child_level_id, second_level.revision)
    end
  end

  test "invalid graph, unsafe budgets, malformed identifiers and nonexistent pages fail explicitly" do
    assert {:error, :invalid_graph} = Atlas.build([device_node(1)], [edge(1, 2, "dangling")])
    assert {:error, :invalid_graph} = Atlas.build([device_node(1)], [edge(1, 1, "self")])
    assert {:error, :invalid_graph} = Atlas.build([%{id: "atlas:aggregate:reserved"}], [])

    assert {:error, :invalid_graph} =
             Atlas.build([Map.put(device_node(1), :site_id, String.duplicate("S", 1_025))], [])

    assert {:error, :duplicate_node} = Atlas.build([device_node(1), device_node(1)], [])
    assert {:error, :invalid_budgets} = Atlas.build([], [], node_budget: 129)
    assert {:error, :invalid_budgets} = Atlas.build([], [], label_budget: 0)
    assert {:ok, empty} = Atlas.build([], [])
    assert {:ok, %{nodes: [], edges: [], next_level_id: nil}} = Atlas.fetch(empty)

    for id <- ["invalid", "global:-1:0", "global:0:no", "members:not*base64:0:0", nil] do
      assert {:error, :invalid_level} = Atlas.fetch(empty, id)
    end

    for id <- ["global:1:0", "global:0:1", "neighborhood:aG9zdDAxLmV4YW1wbGUuY29t:0:0"] do
      assert {:error, :not_found} = Atlas.fetch(empty, id)
    end

    assert {:ok, blank_labels} =
             Atlas.build([Map.put(%{device_node(1) | label: ""}, :site_id, "")], [])

    label = id(1)
    assert {:ok, %{nodes: [%{label: ^label, child_level_id: child}]}} = Atlas.fetch(blank_labels)
    assert {:ok, %{nodes: [%{label: ^label}]}} = Atlas.fetch(blank_labels, child)
  end

  test "site aggregates retain cross-site relation counts and long identities remain navigable" do
    long_id = String.duplicate("a", 1_012) <> ".example.com"

    nodes = [
      %{id: long_id, site_id: "SITE01", label: "host01.example.com"},
      %{
        id: "host02.example.com",
        site_id: String.duplicate("S", 1_024),
        label: "host02.example.com"
      }
    ]

    edges = [
      %{
        source: long_id,
        target: "host02.example.com",
        relation_id: "cross-site",
        evidence_class: "direct-physical"
      }
    ]

    assert {:ok, index} = Atlas.build(nodes, edges)
    assert {:ok, global} = Atlas.fetch(index)
    assert [%{relation_count: 1, aggregate: true}] = global.edges
    assert Enum.all?(global.nodes, &(&1.member_count == 1 and &1.cross_link_count == 1))
    levels = walk(index)

    assert Enum.any?(levels, fn level ->
             Enum.any?(level.edges, &(&1[:relation_id] == "cross-site"))
           end)
  end

  test "hosted guests page as members without bridging their infrastructure parents" do
    nodes = Enum.map(1..152, &device_node/1)

    edges =
      Enum.map(3..152, fn guest ->
        evidence = if rem(guest, 2) == 0, do: "hosted", else: "hosted-virtual"
        edge(1, guest, "hosted-#{guest}", evidence)
      end) ++ [edge(2, 3, "secondary-host", "hosted")]

    assert {:ok, index} = Atlas.build(nodes, edges)

    assert {:ok, %{counts: %{members: 152, aggregates: 2}, edges: [%{relation_count: 1}]}} =
             Atlas.fetch(index)

    levels = walk(index)

    reached_guests =
      levels
      |> Enum.filter(&(&1.kind == "members"))
      |> Enum.flat_map(& &1.nodes)
      |> Enum.reject(&(&1.id in [id(1), id(2)]))
      |> MapSet.new(& &1.id)

    assert reached_guests == MapSet.new(3..152, &id/1)
    for level <- levels, do: assert_bounded(level)
  end

  @tag timeout: 180_000
  test "a seeded 200k-node 400k-relation canonical graph exposes only bounded level pages" do
    {nodes, edges} = carrier_graph(200, 1_000, 481)
    assert length(nodes) == 200_000
    assert length(edges) == 400_000
    assert {:ok, index} = Atlas.build(nodes, edges)
    global_pages = pages(index, "global")

    assert Enum.all?(
             global_pages,
             &(&1.counts.members == 200_000 and &1.counts.relations == 400_000)
           )

    aggregates = Enum.flat_map(global_pages, & &1.nodes)
    assert Enum.sum(Enum.map(aggregates, & &1.member_count)) == 200_000
    assert Enum.sum(Enum.map(aggregates, & &1.relation_count)) == 400_000

    for global <- global_pages, do: assert_bounded(global)

    for aggregate <- [hd(aggregates), List.last(aggregates)] do
      assert {:ok, component} = Atlas.fetch(index, aggregate.child_level_id)
      anchor = Enum.find(component.nodes, &(not Map.get(&1, :aggregate, false)))
      assert {:ok, neighborhood} = Atlas.fetch(index, anchor.child_level_id)
      group = Enum.find(neighborhood.nodes, &Map.get(&1, :aggregate, false))
      members = pages(index, group.child_level_id)

      reached =
        members
        |> Enum.flat_map(& &1.nodes)
        |> Enum.reject(&(&1.id == anchor.id))
        |> MapSet.new(& &1.id)

      assert MapSet.size(reached) == 998
      for level <- [component, neighborhood | members], do: assert_bounded(level)
    end
  end

  defp assert_bounded(level) do
    assert length(level.nodes) <= min(level.budgets.nodes, level.budgets.labels)
    assert length(level.edges) <= level.budgets.edges
    assert Enum.all?(level.nodes, &(is_binary(&1.label) and byte_size(&1.label) > 0))
    node_ids = MapSet.new(level.nodes, & &1.id)

    assert Enum.all?(
             level.edges,
             &(MapSet.member?(node_ids, &1.source) and MapSet.member?(node_ids, &1.target))
           )

    assert level.revision >= 0 and level.revision <= 9_007_199_254_740_991

    if level.kind == "members", do: assert(length(level.nodes) <= level.budgets.members + 1)
  end

  defp walk(index), do: walk(index, ["global"], MapSet.new(), [])
  defp walk(_index, [], _seen, levels), do: Enum.reverse(levels)

  defp walk(index, [id | remaining], seen, levels) do
    if MapSet.member?(seen, id) do
      walk(index, remaining, seen, levels)
    else
      assert {:ok, level} = Atlas.fetch(index, id)
      children = Enum.map(level.nodes, &Map.get(&1, :child_level_id))
      next = Enum.reject([level.next_level_id | children], &is_nil/1)
      walk(index, next ++ remaining, MapSet.put(seen, id), [level | levels])
    end
  end

  defp pages(index, id), do: pages(index, id, [])
  defp pages(_index, nil, acc), do: Enum.reverse(acc)

  defp pages(index, id, acc) do
    assert {:ok, level} = Atlas.fetch(index, id)
    pages(index, level.next_level_id, [level | acc])
  end

  defp small_graph do
    nodes = Enum.map(1..23, &device_node/1)
    backbone = Enum.map(2..8, &edge(1, &1, "backbone-#{&1}"))

    cross_links =
      for source <- 2..4,
          target <- (source + 1)..5,
          do: edge(source, target, "cross-#{source}-#{target}")

    members =
      for member <- 9..17, anchor <- [1, 2] do
        edge(anchor, member, "member-#{anchor}-#{member}", "endpoint-attachment")
      end

    {nodes, backbone ++ cross_links ++ members ++ [edge(1, 2, "parallel")]}
  end

  defp carrier_graph(groups, group_size, seed) do
    nodes = Enum.map(1..(groups * group_size), &device_node/1)

    edges =
      Enum.flat_map(0..(groups - 1), fn group ->
        base = group * group_size
        backbone = Enum.map(1..4, &edge(base + 1, base + 2, "backbone-#{group}-#{&1}"))

        members =
          for member <- (base + 3)..(base + group_size), anchor <- [base + 1, base + 2] do
            anchor
            |> edge(member, "member-#{anchor}-#{member}", "endpoint-attachment")
            |> Map.put(:flow_pps, rem(member * 104_729 + seed, 101))
          end

        backbone ++ members
      end)

    {nodes, edges}
  end

  defp device_node(number), do: %{id: id(number), label: "host#{number}.example.com"}

  defp id(number), do: "sr:host#{String.pad_leading(Integer.to_string(number), 6, "0")}.example.com"

  defp edge(source, target, relation_id, evidence_class \\ "direct-physical") do
    %{
      source: id(source),
      target: id(target),
      relation_id: relation_id,
      evidence_class: evidence_class,
      flow_pps: 1
    }
  end
end
