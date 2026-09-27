defmodule ServiceRadarWebNG.Topology.WorldFlowTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.WorldFlow

  @moduletag :db_free

  @now ~U[2001-04-05 06:07:08Z]
  @settings %{window_seconds: 900, freshness_seconds: 120, timeout_ms: 5_000}

  # Every identity and observation here is invented. These tests own attribution
  # and coverage; the shared SRQL DB suite owns counter derivatives and routing.
  test "single-link measured zero remains measured and reverse mapping chooses one endpoint" do
    link = relation("first", "edge-first")
    request = WorldFlow.request([link], @now, @settings)

    rows =
      packets(link.source_id, "out", [0, 0, 0]) ++
        packets(link.target_id, "in", [70, 80, 90]) ++
        packets(link.target_id, "out", [1, 2, 3]) ++ packets(link.source_id, "in", [40, 50, 60])

    [edge] = summary([link], [%{id: "edge-first", count: 1}], rows, request).edges
    assert edge.forward.status == :measured
    assert edge.forward.packets_per_second == 0
    refute edge.forward.animate
    assert edge.reverse.packets_per_second == 6
    assert edge.reverse.animate
    assert edge.reverse.packet_interval.observed_at == DateTime.add(@now, -10, :second)
    assert edge.reverse.packet_interval.previous_observed_at == DateTime.add(@now, -70, :second)

    [reversed] = summary([%{link | reversed: true}], [%{id: "edge-first", count: 1}], rows, request).edges
    assert reversed.forward.packets_per_second == 6
    assert reversed.reverse.packets_per_second == 0
  end

  test "bundle membership and wholly unselected edges never extrapolate sampled traffic" do
    first = relation("first", "bundle")
    second = relation("second", "bundle")
    request = WorldFlow.request([first, second], @now, @settings)
    rows = packets(first.source_id, "out", [1, 2, 3]) ++ packets(second.source_id, "out", [4, 5, 6])
    edges = [%{id: "bundle", count: 3}, %{id: "unseen", count: 8}]
    result = summary([first, second], edges, rows, request)
    assert result.coverage.rendered_relations == 11
    assert result.coverage.selected_relations == 2
    [partial, unseen] = result.edges
    assert partial.forward.packet_observed_relations == 2
    assert partial.forward.packets_per_second == nil
    refute partial.forward.animate
    assert partial.eligibility.unselected == 1
    assert unseen.forward.status == :unknown
    assert unseen.eligibility.unselected == 8

    [complete] = summary([first, second], [%{id: "bundle", count: 2}], rows, request).edges
    assert complete.forward.packets_per_second == 21
    assert complete.forward.packet_observed_relations == 2
  end

  test "incomplete, stale or ambiguous packet families stay unknown independently of octets" do
    link = relation("family", "edge")
    request = WorldFlow.request([link], @now, @settings)
    valid = packets(link.source_id, "out", [1, 2, 3])
    octets = [rate(link.source_id, "out", "octets", 25)]
    fallback = packets(link.target_id, "in", [9, 10, 11])

    [edge] = summary([link], [%{id: "edge", count: 1}], tl(valid) ++ octets, request).edges
    assert edge.forward.packets_per_second == nil
    assert edge.forward.octets_per_second == 25

    for {gateway, agent} <- [{nil, nil}, {"gateway.example.com", nil}, {"unknown", "agent.example.com"}, {"", ""}] do
      unidentified = Enum.map(valid, &Map.merge(&1, %{"gateway_id" => gateway, "agent_id" => agent}))
      [edge] = summary([link], [%{id: "edge", count: 1}], unidentified ++ octets, request).edges
      assert edge.forward.packets_per_second == nil
      assert edge.forward.octets_per_second == 25
      refute edge.forward.animate
    end

    for broken <- [
          List.update_at(valid, 0, &Map.put(&1, "status", "ambiguous")),
          List.update_at(valid, 0, &Map.put(&1, "agent_id", "other-producer.example.com"))
        ] do
      [edge] = summary([link], [%{id: "edge", count: 1}], broken ++ fallback, request).edges
      assert edge.forward.status == :unknown
      assert edge.forward.packet_observed_relations == 0
      refute edge.forward.animate
    end

    stale =
      Enum.map(
        valid,
        &Map.merge(&1, %{
          "observed_at" => DateTime.add(@now, -121, :second),
          "previous_observed_at" => DateTime.add(@now, -181, :second)
        })
      )

    [edge] = summary([link], [%{id: "edge", count: 1}], stale ++ fallback, request).edges
    assert edge.forward.packets_per_second == 30
    [unknown] = summary([link], [%{id: "edge", count: 1}], stale, request).edges
    assert unknown.forward.packets_per_second == nil
  end

  test "globally shared interface observations cannot be multiplied across canonical links" do
    link = %{relation("shared", "edge") | source_interface_degree: 2}
    request = WorldFlow.request([link], @now, @settings)
    assert request.pairs == [{link.target_id, 7}]
    rows = packets(link.source_id, "out", [50, 60, 70]) ++ packets(link.target_id, "in", [1, 2, 3])
    [edge] = summary([link], [%{id: "edge", count: 1}], rows, request).edges
    assert edge.forward.packets_per_second == 6

    shared = %{link | target_interface_degree: 3}
    request = WorldFlow.request([shared], @now, @settings)
    assert request.pairs == []
    [edge] = summary([shared], [%{id: "edge", count: 1}], rows, request).edges
    assert edge.eligibility.shared_interface == 1
    assert edge.forward.packets_per_second == nil
    refute edge.forward.animate
  end

  test "physical evidence and identity byte budgets constrain attribution without changing identities" do
    base = relation("eligible", "edge")

    excluded =
      for {evidence, role} <- [
            {"hosted-virtual", nil},
            {"endpoint-attachment", nil},
            {"inferred-segment", nil},
            {"direct-logical", nil},
            {"path", nil},
            {nil, nil},
            {"direct-physical", "virtual"}
          ],
          do: %{base | evidence_class: evidence, role: role}

    for link <- excluded do
      request = WorldFlow.request([link], @now, @settings)
      assert request.pairs == []
      [edge] = summary([link], [%{id: "edge", count: 1}], packets(link.source_id, "out", [1, 2, 3]), request).edges
      assert edge.forward.packet_observed_relations == 0
      refute edge.forward.animate
    end

    huge = %{base | source_id: "sr:" <> String.duplicate("x", 1_048_576)}
    request = WorldFlow.request([huge, base, base], @now, @settings)
    assert request.omitted_pairs == 1
    assert Enum.sort(request.pairs) == Enum.sort([{base.source_id, 7}, {base.target_id, 7}])
    refute Enum.any?(request.pairs, fn {id, _} -> String.starts_with?(id, "sr:x") end)
    assert request.until == @now
    assert request.fresh_after == DateTime.add(@now, -120, :second)
  end

  defp relation(suffix, edge) do
    %{
      relation_id: "synthetic-link-#{suffix}",
      rendered_edge_id: edge,
      source_id: "sr:source-#{suffix}",
      target_id: "sr:target-#{suffix}",
      source_if_index: 7,
      target_if_index: 7,
      reversed: false,
      source_interface_degree: 1,
      target_interface_degree: 1,
      evidence_class: "direct-physical",
      role: nil
    }
  end

  defp summary(relations, edges, rows, request) do
    WorldFlow.summarize(
      edges,
      %{
        relations: relations,
        total_rendered_relations: Enum.sum(Enum.map(edges, & &1.count)),
        candidates: length(relations),
        next_cursor: nil
      },
      rows,
      request
    )
  end

  defp packets(id, direction, rates) do
    ["unicast_packets", "multicast_packets", "broadcast_packets"]
    |> Enum.zip(rates)
    |> Enum.map(fn {family, value} -> rate(id, direction, family, value) end)
  end

  defp rate(id, direction, family, value) do
    %{
      "device_id" => id,
      "if_index" => 7,
      "direction" => direction,
      "family" => family,
      "gateway_id" => "gateway.example.com",
      "agent_id" => "agent.example.com",
      "rate" => value,
      "status" => "measured",
      "observed_at" => DateTime.add(@now, -10, :second),
      "previous_observed_at" => DateTime.add(@now, -70, :second)
    }
  end
end
