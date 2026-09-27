defmodule ServiceRadarWebNG.Topology.Atlas do
  @moduledoc """
  Immutable semantic index of the complete canonical topology.

  Build once when the canonical source changes. Fetches return one bounded level;
  no inventory queries, layout, endpoint collapsing, or graph-wide encoding runs
  on that path. Transport components fall back to a stable member identity when
  site metadata is absent. Endpoint membership belongs to a deterministic anchor.

  Node and relation pages are independently bounded. A dense level can therefore
  have several relation pages with the same nodes. `next_level_id` traverses those
  pages before advancing the node page. Neighborhoods make relations crossing a
  component's node-page boundary inspectable.
  """

  @defaults %{nodes: 128, edges: 256, labels: 128, members: 64}
  @attachment_classes ~w(endpoint-attachment observed-only observed inferred-segment hosted hosted-virtual)
  @edge_identity_fields ~w(id link_key relation_id protocol evidence_class relation_type local_if_index local_if_name
                          neighbor_if_index neighbor_if_name local_if_index_ab local_if_name_ab local_if_index_ba local_if_name_ba
                          topology_class)a

  @type index :: map()
  @type level :: map()

  @spec build([map()], [map()], keyword()) :: {:ok, index()} | {:error, atom()}
  def build(nodes, edges, opts \\ [])

  def build(nodes, edges, opts) when is_list(nodes) and is_list(edges) and is_list(opts) do
    budgets = %{
      nodes: Keyword.get(opts, :node_budget, @defaults.nodes),
      edges: Keyword.get(opts, :edge_budget, @defaults.edges),
      labels: Keyword.get(opts, :label_budget, @defaults.labels),
      members: Keyword.get(opts, :member_page_size, @defaults.members)
    }

    with :ok <- validate_budgets(budgets),
         {:ok, nodes_by_id} <- index_nodes(nodes),
         :ok <- validate_edges(edges, nodes_by_id) do
      edges = Enum.sort_by(edges, &edge_order/1)
      infrastructure = infrastructure_ids(edges, nodes_by_id)
      owners = attachment_owners(edges, infrastructure)
      component_for = component_membership(nodes_by_id, edges, infrastructure, owners)
      components = index_components(nodes_by_id, component_for, infrastructure)
      component_ids = components |> Map.keys() |> Enum.sort() |> List.to_tuple()
      {members, membership_edges} = index_memberships(edges, infrastructure)

      {:ok,
       %{
         revision: fingerprint({Enum.sort(nodes_by_id), edges}),
         budgets: budgets,
         nodes: nodes_by_id,
         edges: List.to_tuple(edges),
         pairs: index_pairs(edges),
         peers: index_peers(edges, infrastructure),
         incident_counts: incident_counts(edges),
         infrastructure: infrastructure,
         owners: owners,
         members: members,
         membership_edges: membership_edges,
         component_for: component_for,
         components: components,
         component_ids: component_ids,
         component_positions: positions(Tuple.to_list(component_ids)),
         infrastructure_positions: infrastructure_positions(components),
         component_counts: component_counts(edges, component_for),
         global_pairs: edges |> aggregate_global_edges(component_for) |> index_pairs()
       }}
    end
  end

  def build(_nodes, _edges, _opts), do: {:error, :invalid_graph}

  @spec fetch(index(), String.t(), non_neg_integer() | nil) ::
          {:ok, level()}
          | {:error, :not_found | :invalid_level | {:stale_revision, non_neg_integer()}}
  def fetch(index, level_id \\ "global", revision \\ nil) do
    with {:ok, address} <- parse_level_id(level_id),
         {:ok, level} <- project(index, address),
         :ok <- validate_relation_page(level, index.budgets.edges),
         level = finish_level(index, address, level),
         :ok <- check_revision(revision, level.revision) do
      {:ok, level}
    end
  end

  defp validate_budgets(%{nodes: nodes, edges: edges, labels: labels, members: members})
       when is_integer(nodes) and nodes >= 4 and nodes <= 128 and is_integer(edges) and edges > 0 and edges <= 256 and
              is_integer(labels) and labels >= 4 and labels <= 128 and is_integer(members) and members > 0 and
              members <= 64, do: :ok

  defp validate_budgets(_budgets), do: {:error, :invalid_budgets}

  defp index_nodes(nodes) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn
      %{id: id} = node, {:ok, acc}
      when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 1_024 ->
        cond do
          String.starts_with?(id, "atlas:") or not valid_site_id?(Map.get(node, :site_id)) ->
            {:halt, {:error, :invalid_graph}}

          Map.has_key?(acc, id) ->
            {:halt, {:error, :duplicate_node}}

          true ->
            {:cont, {:ok, Map.put(acc, id, node)}}
        end

      _, _ ->
        {:halt, {:error, :invalid_graph}}
    end)
  end

  defp valid_site_id?(nil), do: true
  defp valid_site_id?(site), do: is_binary(site) and byte_size(site) <= 1_024

  defp validate_edges(edges, nodes) do
    if Enum.all?(edges, fn
         %{source: source, target: target} ->
           source != target and Map.has_key?(nodes, source) and Map.has_key?(nodes, target)

         _ ->
           false
       end) do
      :ok
    else
      {:error, :invalid_graph}
    end
  end

  defp infrastructure_ids(edges, nodes) do
    transport =
      edges
      |> Enum.reject(&attachment?/1)
      |> Enum.flat_map(&[&1.source, &1.target])
      |> MapSet.new()

    anchors =
      Enum.reduce(edges, transport, fn edge, acc ->
        if MapSet.member?(transport, edge.source) or MapSet.member?(transport, edge.target) do
          acc
        else
          MapSet.put(acc, edge.source)
        end
      end)

    connected = edges |> Enum.flat_map(&[&1.source, &1.target]) |> MapSet.new()

    Enum.reduce(Map.keys(nodes), anchors, fn id, acc ->
      if MapSet.member?(connected, id), do: acc, else: MapSet.put(acc, id)
    end)
  end

  defp attachment_owners(edges, infrastructure) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      case {MapSet.member?(infrastructure, edge.source), MapSet.member?(infrastructure, edge.target)} do
        {true, false} -> Map.update(acc, edge.target, edge.source, &min(&1, edge.source))
        {false, true} -> Map.update(acc, edge.source, edge.target, &min(&1, edge.target))
        _ -> acc
      end
    end)
  end

  defp index_memberships(edges, infrastructure) do
    {groups, summaries} =
      Enum.reduce(edges, {%{}, %{}}, fn edge, acc ->
        case {MapSet.member?(infrastructure, edge.source), MapSet.member?(infrastructure, edge.target)} do
          {true, false} -> add_membership(acc, edge.source, edge.target, edge)
          {false, true} -> add_membership(acc, edge.target, edge.source, edge)
          _ -> acc
        end
      end)

    {sorted_tuples(groups), summaries}
  end

  defp add_membership({groups, summaries}, anchor, member, edge) do
    groups = Map.update(groups, anchor, MapSet.new([member]), &MapSet.put(&1, member))

    summary = %{
      source: anchor,
      target: membership_id(anchor),
      aggregate: true,
      relation_count: 1,
      evidence_class: "endpoint-attachment",
      flow_pps: Map.get(edge, :flow_pps, 0),
      flow_bps: Map.get(edge, :flow_bps, 0)
    }

    summaries =
      Map.update(summaries, anchor, summary, fn existing ->
        %{
          existing
          | relation_count: existing.relation_count + 1,
            flow_pps: existing.flow_pps + summary.flow_pps,
            flow_bps: existing.flow_bps + summary.flow_bps
        }
      end)

    {groups, summaries}
  end

  defp component_membership(nodes, edges, infrastructure, owners) do
    parents = Map.new(infrastructure, &{&1, &1})

    {parents, _ranks} =
      edges
      |> Enum.reject(&attachment?/1)
      |> Enum.reduce({parents, %{}}, &union/2)

    roots = Enum.group_by(infrastructure, &root(parents, &1))
    component_names = Map.new(roots, fn {root, ids} -> {root, "component:" <> Enum.min(ids)} end)

    infrastructure_components =
      Map.new(infrastructure, fn id ->
        component =
          case Map.get(nodes[id], :site_id) do
            site when is_binary(site) and byte_size(site) > 0 -> "site:" <> site
            _ -> Map.fetch!(component_names, root(parents, id))
          end

        {id, component}
      end)

    Map.new(nodes, fn {id, _node} ->
      anchor = Map.get(owners, id, id)
      {id, Map.fetch!(infrastructure_components, anchor)}
    end)
  end

  defp union(edge, {parents, ranks}) do
    source = root(parents, edge.source)
    target = root(parents, edge.target)
    source_rank = Map.get(ranks, source, 0)
    target_rank = Map.get(ranks, target, 0)

    cond do
      source == target -> {parents, ranks}
      source_rank < target_rank -> {Map.put(parents, source, target), ranks}
      source_rank > target_rank -> {Map.put(parents, target, source), ranks}
      true -> {Map.put(parents, target, source), Map.put(ranks, source, source_rank + 1)}
    end
  end

  defp root(parents, id) do
    case Map.fetch!(parents, id) do
      ^id -> id
      parent -> root(parents, parent)
    end
  end

  defp index_components(nodes, component_for, infrastructure) do
    nodes
    |> Map.keys()
    |> Enum.group_by(&Map.fetch!(component_for, &1))
    |> Map.new(fn {component, ids} ->
      backbone = ids |> Enum.filter(&MapSet.member?(infrastructure, &1)) |> Enum.sort()
      {component, %{members: length(ids), infrastructure: List.to_tuple(backbone)}}
    end)
  end

  defp index_pairs(edges) do
    edges
    |> Enum.group_by(&pair_key(&1.source, &1.target))
    |> Map.new(fn {pair, relations} -> {pair, List.to_tuple(relations)} end)
  end

  defp index_peers(edges, infrastructure) do
    edges
    |> Enum.reduce(%{}, fn edge, acc ->
      if edge.source != edge.target and MapSet.member?(infrastructure, edge.source) and
           MapSet.member?(infrastructure, edge.target) do
        acc
        |> Map.update(edge.source, MapSet.new([edge.target]), &MapSet.put(&1, edge.target))
        |> Map.update(edge.target, MapSet.new([edge.source]), &MapSet.put(&1, edge.source))
      else
        acc
      end
    end)
    |> sorted_tuples()
  end

  defp incident_counts(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      acc = Map.update(acc, edge.source, 1, &(&1 + 1))
      if edge.source == edge.target, do: acc, else: Map.update(acc, edge.target, 1, &(&1 + 1))
    end)
  end

  defp component_counts(edges, component_for) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      source = Map.fetch!(component_for, edge.source)
      target = Map.fetch!(component_for, edge.target)

      if source == target do
        Map.update(
          acc,
          source,
          %{internal: 1, cross_links: 0},
          &Map.update!(&1, :internal, fn n -> n + 1 end)
        )
      else
        Enum.reduce([source, target], acc, fn component, counts ->
          Map.update(
            counts,
            component,
            %{internal: 0, cross_links: 1},
            &Map.update!(&1, :cross_links, fn n -> n + 1 end)
          )
        end)
      end
    end)
  end

  defp aggregate_global_edges(edges, component_for) do
    edges
    |> Enum.reduce(%{}, fn edge, acc ->
      source = Map.fetch!(component_for, edge.source)
      target = Map.fetch!(component_for, edge.target)

      if source == target do
        acc
      else
        pair = Enum.min_max([source, target])
        Map.update(acc, pair, 1, &(&1 + 1))
      end
    end)
    |> Enum.sort()
    |> Enum.map(fn {{source, target}, count} ->
      %{
        source: aggregate_id(source),
        target: aggregate_id(target),
        relation_count: count,
        aggregate: true
      }
    end)
  end

  defp project(index, {"global", nil, page, edge_page}) do
    ids = tuple_page(index.component_ids, page, node_limit(index))

    if ids == [] and page > 0 do
      {:error, :not_found}
    else
      nodes = Enum.map(ids, &component_node(index, &1))
      edges = pair_groups(index.global_pairs, Enum.map(nodes, & &1.id))

      {:ok,
       page_level(
         nodes,
         edges,
         page,
         edge_page,
         tuple_size(index.component_ids),
         node_limit(index),
         nil,
         %{
           members: map_size(index.nodes),
           relations: tuple_size(index.edges),
           aggregates: tuple_size(index.component_ids)
         }
       )}
    end
  end

  defp project(index, {"component", component_id, page, edge_page}) do
    with {:ok, component} <- find(index.components, component_id),
         {:ok, ids} <- nonempty_page(component.infrastructure, page, component_page_size(index)) do
      nodes =
        ids
        |> Enum.flat_map(&[device_node(index, &1), membership_node(index, &1)])
        |> Enum.reject(&is_nil/1)

      edges = pair_groups(index.pairs, ids) ++ membership_groups(index, ids)
      parent_page = div(Map.fetch!(index.component_positions, component_id), node_limit(index))
      counts = Map.get(index.component_counts, component_id, %{internal: 0, cross_links: 0})

      {:ok,
       page_level(
         nodes,
         edges,
         page,
         edge_page,
         tuple_size(component.infrastructure),
         component_page_size(index),
         level_id({"global", nil, parent_page, 0}),
         %{
           members: component.members,
           relations: counts.internal,
           cross_links: counts.cross_links
         }
       )}
    end
  end

  defp project(index, {"neighborhood", anchor, page, edge_page}) do
    with :ok <- validate_anchor(index, anchor) do
      peers = Map.get(index.peers, anchor, {})
      page_size = node_limit(index) - 2
      ids = tuple_page(peers, page, page_size)

      if ids == [] and page > 0 do
        {:error, :not_found}
      else
        nodes = [device_node(index, anchor) | Enum.map(ids, &device_node(index, &1))]
        nodes = Enum.reject(nodes ++ [membership_node(index, anchor)], &is_nil/1)
        edges = pair_groups(index.pairs, [anchor | ids]) ++ membership_groups(index, [anchor])
        component = Map.fetch!(index.component_for, anchor)

        component_page =
          div(Map.fetch!(index.infrastructure_positions, anchor), component_page_size(index))

        {:ok,
         page_level(
           nodes,
           edges,
           page,
           edge_page,
           tuple_size(peers),
           page_size,
           level_id({"component", component, component_page, 0}),
           %{
             members: tuple_size(peers) + member_count(index, anchor) + 1,
             relations: incident_count(index, anchor)
           }
         )}
      end
    end
  end

  defp project(index, {"members", anchor, page, edge_page}) do
    with :ok <- validate_anchor(index, anchor),
         {:ok, members} <- find(index.members, anchor),
         {:ok, ids} <- nonempty_page(members, page, member_page_size(index)) do
      nodes = [device_node(index, anchor) | Enum.map(ids, &device_node(index, &1))]

      {:ok,
       page_level(
         nodes,
         pair_groups(index.pairs, [anchor | ids]),
         page,
         edge_page,
         tuple_size(members),
         member_page_size(index),
         level_id({"neighborhood", anchor, 0, 0}),
         %{members: tuple_size(members), relations: incident_count(index, anchor)}
       )}
    end
  end

  defp page_level(nodes, edges, page, edge_page, total, page_size, parent, counts) do
    %{
      nodes: nodes,
      edge_groups: edges,
      relation_count: Enum.reduce(edges, 0, &(tuple_size(&1) + &2)),
      parent_level_id: parent,
      counts: counts,
      page: page,
      edge_page: edge_page,
      has_next_node_page: (page + 1) * page_size < total
    }
  end

  defp finish_level(index, {kind, scope, page, edge_page} = address, level) do
    relation_count = level.relation_count
    edges = relation_page(level.edge_groups, edge_page * index.budgets.edges, index.budgets.edges)

    next =
      cond do
        (edge_page + 1) * index.budgets.edges < relation_count ->
          level_id({kind, scope, page, edge_page + 1})

        level.has_next_node_page ->
          level_id({kind, scope, page + 1, 0})

        true ->
          nil
      end

    envelope = %{
      level_id: level_id(address),
      parent_level_id: level.parent_level_id,
      kind: kind,
      nodes: level.nodes,
      edges: edges,
      next_level_id: next,
      counts:
        Map.merge(level.counts, %{
          visible_nodes: length(level.nodes),
          visible_relations: length(edges)
        }),
      budgets: index.budgets
    }

    structure = {
      Enum.map(level.nodes, &node_identity/1),
      Enum.map(edges, &edge_identity/1),
      next
    }

    envelope
    |> Map.put(:revision, fingerprint(envelope))
    |> Map.put(:structure_revision, fingerprint(structure))
  end

  defp component_node(index, component_id) do
    component = Map.fetch!(index.components, component_id)
    first_id = elem(component.infrastructure, 0)
    counts = Map.get(index.component_counts, component_id, %{internal: 0, cross_links: 0})

    %{
      id: aggregate_id(component_id),
      label:
        first_label([
          Map.get(index.nodes[first_id], :site_id),
          Map.get(index.nodes[first_id], :label),
          first_id
        ]),
      aggregate: true,
      member_count: component.members,
      relation_count: counts.internal,
      cross_link_count: counts.cross_links,
      child_level_id: level_id({"component", component_id, 0, 0})
    }
  end

  defp device_node(index, id) do
    child = if MapSet.member?(index.infrastructure, id), do: level_id({"neighborhood", id, 0, 0})

    index.nodes
    |> Map.fetch!(id)
    |> Map.put(:label, first_label([Map.get(index.nodes[id], :label), id]))
    |> Map.put(:child_level_id, child)
  end

  defp membership_node(index, anchor) do
    count = member_count(index, anchor)

    if count > 0 do
      %{
        id: membership_id(anchor),
        label: "#{count} endpoint members",
        aggregate: true,
        member_count: count,
        child_level_id: level_id({"members", anchor, 0, 0})
      }
    end
  end

  defp membership_groups(index, anchors) do
    Enum.flat_map(anchors, fn anchor ->
      case Map.fetch(index.membership_edges, anchor) do
        {:ok, edge} -> [{edge}]
        :error -> []
      end
    end)
  end

  defp pair_groups(pairs, ids), do: collect_pair_groups(pairs, Enum.sort(ids), [])
  defp collect_pair_groups(_pairs, [], groups), do: Enum.reverse(groups)

  defp collect_pair_groups(pairs, [id | rest] = ids, groups) do
    groups =
      Enum.reduce(ids, groups, fn peer, acc ->
        case Map.fetch(pairs, {id, peer}) do
          {:ok, relations} -> [relations | acc]
          :error -> acc
        end
      end)

    collect_pair_groups(pairs, rest, groups)
  end

  defp relation_page(groups, offset, size), do: collect_relations(groups, offset, size, [])
  defp collect_relations(_groups, _offset, 0, acc), do: Enum.reverse(acc)
  defp collect_relations([], _offset, _size, acc), do: Enum.reverse(acc)

  defp collect_relations([group | rest], offset, size, acc) when offset >= tuple_size(group) do
    collect_relations(rest, offset - tuple_size(group), size, acc)
  end

  defp collect_relations([group | rest], offset, size, acc) do
    count = min(tuple_size(group) - offset, size)
    acc = Enum.reduce(offset..(offset + count - 1), acc, &[elem(group, &1) | &2])
    collect_relations(rest, 0, size - count, acc)
  end

  defp incident_count(index, anchor), do: Map.get(index.incident_counts, anchor, 0)
  defp member_count(index, anchor), do: index.members |> Map.get(anchor, {}) |> tuple_size()
  defp node_limit(index), do: min(index.budgets.nodes, index.budgets.labels)
  defp component_page_size(index), do: div(node_limit(index), 2)
  defp member_page_size(index), do: min(index.budgets.members, node_limit(index) - 1)

  defp aggregate_id(component), do: "atlas:aggregate:" <> Base.url_encode64(component, padding: false)

  defp membership_id(anchor), do: "atlas:members:" <> Base.url_encode64(anchor, padding: false)
  defp attachment?(edge), do: Map.get(edge, :evidence_class) in @attachment_classes
  defp pair_key(source, target) when source <= target, do: {source, target}
  defp pair_key(source, target), do: {target, source}

  defp edge_identity(edge) do
    metadata = Map.get(edge, :metadata) || %{}

    semantics =
      Map.take(metadata, [
        :connectivity_forest_bridge,
        :topology_plane,
        "connectivity_forest_bridge",
        "topology_plane"
      ])

    {edge.source, edge.target, Map.take(edge, @edge_identity_fields), semantics}
  end

  defp node_identity(node) do
    details = Map.get(node, :details) || %{}

    semantics =
      Map.take(details, [
        :type,
        :cluster_kind,
        :cluster_expanded,
        "type",
        "cluster_kind",
        "cluster_expanded"
      ])

    {Map.take(node, [:id, :child_level_id, :aggregate, :kind, :cluster_kind, :type]), semantics}
  end

  defp first_label(values), do: Enum.find(values, &(is_binary(&1) and String.trim(&1) != ""))

  defp edge_order(edge), do: {edge_identity(edge), :erlang.term_to_binary(edge, [:deterministic])}
  defp positions(ids), do: ids |> Enum.with_index() |> Map.new()

  defp sorted_tuples(groups), do: Map.new(groups, fn {id, values} -> {id, values |> Enum.sort() |> List.to_tuple()} end)

  defp infrastructure_positions(components) do
    Enum.reduce(components, %{}, fn {_component, %{infrastructure: ids}}, acc ->
      Map.merge(acc, ids |> Tuple.to_list() |> positions())
    end)
  end

  defp tuple_page(tuple, page, size) do
    first = page * size
    last = min(first + size, tuple_size(tuple)) - 1
    if first > last, do: [], else: Enum.map(first..last, &elem(tuple, &1))
  end

  defp nonempty_page(tuple, page, size) do
    case tuple_page(tuple, page, size) do
      [] -> {:error, :not_found}
      ids -> {:ok, ids}
    end
  end

  defp find(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  defp validate_anchor(index, anchor) do
    if MapSet.member?(index.infrastructure, anchor), do: :ok, else: {:error, :not_found}
  end

  defp level_id({"global", nil, 0, 0}), do: "global"
  defp level_id({"global", nil, page, edge_page}), do: "global:#{page}:#{edge_page}"

  defp level_id({kind, scope, page, edge_page}) do
    "#{kind}:#{Base.url_encode64(scope, padding: false)}:#{page}:#{edge_page}"
  end

  defp parse_level_id("global"), do: {:ok, {"global", nil, 0, 0}}

  defp parse_level_id(id) when is_binary(id) and byte_size(id) <= 2_048 do
    case String.split(id, ":") do
      ["global", page, edge_page] ->
        parse_address("global", nil, page, edge_page)

      [kind, scope, page, edge_page] when kind in ["component", "neighborhood", "members"] ->
        case Base.url_decode64(scope, padding: false) do
          {:ok, decoded} -> parse_address(kind, decoded, page, edge_page)
          :error -> {:error, :invalid_level}
        end

      _ ->
        {:error, :invalid_level}
    end
  end

  defp parse_level_id(_id), do: {:error, :invalid_level}

  defp parse_address(kind, scope, page, edge_page) do
    with {page, ""} when page >= 0 <- Integer.parse(page),
         {edge_page, ""} when edge_page >= 0 <- Integer.parse(edge_page) do
      {:ok, {kind, scope, page, edge_page}}
    else
      _ -> {:error, :invalid_level}
    end
  end

  defp check_revision(nil, _current), do: :ok
  defp check_revision(revision, revision), do: :ok
  defp check_revision(_requested, current), do: {:error, {:stale_revision, current}}

  defp validate_relation_page(%{edge_page: 0}, _budget), do: :ok

  defp validate_relation_page(%{edge_page: page, relation_count: count}, budget) do
    if page * budget < count, do: :ok, else: {:error, :not_found}
  end

  defp fingerprint(term) do
    <<value::unsigned-size(52), _::bitstring>> =
      :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

    value
  end
end
