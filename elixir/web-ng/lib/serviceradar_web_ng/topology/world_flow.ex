defmodule ServiceRadarWebNG.Topology.WorldFlow do
  @moduledoc "Bounded interface attribution and honest coverage for rendered topology bundles."

  @packet_families ["unicast_packets", "multicast_packets", "broadcast_packets"]
  @max_request_bytes 1_048_576

  @doc "Builds an exact-pair request without truncating identities that exceed the byte budget."
  def request(relations, now, settings) do
    window = %{
      since: DateTime.add(now, -settings.window_seconds, :second),
      until: now,
      fresh_after: DateTime.add(now, -settings.freshness_seconds, :second)
    }

    candidates = relations |> Enum.flat_map(&pairs/1) |> Enum.uniq()
    overhead = byte_size(Jason.encode!(Map.put(window, :pairs, [])))

    {selected, _bytes} =
      Enum.reduce(candidates, {[], overhead}, fn {id, index} = pair, {selected, bytes} ->
        size = byte_size(Jason.encode!(%{device_id: id, if_index: index})) + if(selected == [], do: 0, else: 1)

        if length(selected) < 512 and bytes + size <= @max_request_bytes,
          do: {[pair | selected], bytes + size},
          else: {selected, bytes}
      end)

    Map.merge(window, %{
      pairs: Enum.reverse(selected),
      requested_pairs: length(candidates),
      omitted_pairs: length(candidates) - length(selected),
      window_seconds: settings.window_seconds,
      freshness_seconds: settings.freshness_seconds,
      timeout_ms: settings.timeout_ms
    })
  end

  @doc "Combines one bounded relation page and current rates; partial bundle totals remain unknown."
  def summarize(edges, page, rows, request) do
    rates = Map.new(rows, &{{&1["device_id"], &1["if_index"], &1["direction"], &1["family"]}, &1})
    grouped = Enum.group_by(page.relations, & &1.rendered_edge_id)

    %{
      edges: Enum.map(edges, &edge_summary(&1, Map.get(grouped, &1.id, []), rates, request)),
      coverage: %{
        rendered_relations: page.total_rendered_relations,
        selected_relations: length(page.relations),
        candidates_examined: page.candidates,
        scan_complete: is_nil(page.next_cursor),
        requested_pairs: request.requested_pairs,
        queried_pairs: length(request.pairs),
        omitted_pairs: request.omitted_pairs
      },
      query: Map.take(request, [:since, :until, :fresh_after, :window_seconds, :freshness_seconds, :timeout_ms])
    }
  end

  defp edge_summary(edge, relations, rates, request) do
    values = Enum.map(relations, &relation_rates(&1, rates, request))

    %{
      id: edge.id,
      total_relations: edge.count,
      selected_relations: length(relations),
      eligibility:
        relations |> Enum.frequencies_by(&eligibility/1) |> Map.put(:unselected, edge.count - length(relations)),
      forward: direction_summary(values, :forward, edge.count),
      reverse: direction_summary(values, :reverse, edge.count)
    }
  end

  defp relation_rates(relation, rates, request) do
    source = if eligibility(relation) == :physical, do: endpoint_pair(relation, :source)
    target = if eligibility(relation) == :physical, do: endpoint_pair(relation, :target)
    forward = directional_rates(source, target, rates, request)
    reverse = directional_rates(target, source, rates, request)

    if relation.reversed,
      do: %{forward: reverse, reverse: forward},
      else: %{forward: forward, reverse: reverse}
  end

  defp directional_rates(source, target, rates, request) do
    %{
      packets: choose(source, target, rates, @packet_families, request),
      octets: choose(source, target, rates, ["octets"], request)
    }
  end

  # One endpoint observes a direction. The opposite endpoint is a fallback,
  # never an additional contribution to the same relation. Ambiguity is not
  # resolved by choosing another producer or hiding it behind that fallback.
  defp choose(source, target, rates, families, request) do
    case endpoint(source, "out", rates, families, request) do
      :unknown -> endpoint(target, "in", rates, families, request)
      result -> result
    end
  end

  defp endpoint(nil, _direction, _rates, _families, _request), do: :unknown

  defp endpoint({id, index}, direction, rates, families, request) do
    rows = Enum.map(families, &Map.get(rates, {id, index, direction, &1}))

    cond do
      Enum.any?(rows, &match?(%{"status" => "ambiguous"}, &1)) ->
        :ambiguous

      Enum.all?(rows, &measured?(&1, request)) ->
        case producer(rows) do
          :ok -> measurement(rows)
          unknown -> unknown
        end

      true ->
        :unknown
    end
  end

  defp measurement(rows) do
    %{
      rate: Enum.reduce(rows, 0, &(&1["rate"] + &2)),
      observed_at: Enum.max_by(rows, & &1["observed_at"], DateTime)["observed_at"],
      earliest_observed_at: Enum.min_by(rows, & &1["observed_at"], DateTime)["observed_at"],
      previous_observed_at: Enum.min_by(rows, & &1["previous_observed_at"], DateTime)["previous_observed_at"]
    }
  end

  # A single uniquely selected family needs no cross-family identity proof.
  # The writer permits absent producer metadata, including a gateway sentinel;
  # matching missing values do not establish a common packet-counter producer.
  defp producer([_single]), do: :ok

  defp producer(rows) do
    identities = Enum.map(rows, &{&1["gateway_id"], &1["agent_id"]})

    cond do
      !Enum.all?(identities, fn {gateway, agent} -> identified?(gateway) and identified?(agent) end) -> :unknown
      length(Enum.uniq(identities)) != 1 -> :ambiguous
      true -> :ok
    end
  end

  defp identified?(value) when is_binary(value), do: String.downcase(String.trim(value)) not in ["", "unknown"]
  defp identified?(_value), do: false

  defp measured?(
         %{
           "status" => "measured",
           "rate" => rate,
           "observed_at" => %DateTime{} = at,
           "previous_observed_at" => %DateTime{} = previous
         },
         request
       )
       when is_number(rate) and rate >= 0 do
    DateTime.compare(at, request.fresh_after) != :lt and
      DateTime.compare(at, request.until) != :gt and DateTime.before?(previous, at)
  end

  defp measured?(_row, _request), do: false

  defp direction_summary(values, direction, total) do
    packets = values |> Enum.map(& &1[direction].packets) |> observed()
    octets = values |> Enum.map(& &1[direction].octets) |> observed()
    packets_complete = total > 0 and length(packets) == total
    octets_complete = total > 0 and length(octets) == total
    pps = if packets_complete, do: sum(packets)

    %{
      status: if(packets_complete, do: :measured, else: :unknown),
      animate: packets_complete and pps > 0,
      packets_per_second: pps,
      octets_per_second: if(octets_complete, do: sum(octets)),
      packet_observed_relations: length(packets),
      octet_observed_relations: length(octets),
      packet_interval: interval(packets),
      octet_interval: interval(octets)
    }
  end

  defp observed(values), do: Enum.filter(values, &is_map/1)
  defp sum(values), do: Enum.reduce(values, 0, &(&1.rate + &2))
  defp interval([]), do: nil

  defp interval(values) do
    %{
      previous_observed_at: Enum.min_by(values, & &1.previous_observed_at, DateTime).previous_observed_at,
      earliest_observed_at: Enum.min_by(values, & &1.earliest_observed_at, DateTime).earliest_observed_at,
      observed_at: Enum.max_by(values, & &1.observed_at, DateTime).observed_at
    }
  end

  defp pairs(relation) do
    if eligibility(relation) == :physical do
      Enum.reject([endpoint_pair(relation, :source), endpoint_pair(relation, :target)], &is_nil/1)
    else
      []
    end
  end

  # The canonical writer normalizes legacy "direct" to "direct-physical".
  # Interface counters on hosted, inferred or attachment edges describe shared
  # ports and cannot be attributed to those individual relationships.
  defp eligibility(relation) do
    cond do
      relation.evidence_class not in ["direct-physical", "direct"] ->
        :not_physical_evidence

      relation.role not in [nil, ""] ->
        :excluded_role

      is_nil(pair(relation.source_id, relation.source_if_index)) and
          is_nil(pair(relation.target_id, relation.target_if_index)) ->
        :missing_interface_binding

      is_nil(endpoint_pair(relation, :source)) and is_nil(endpoint_pair(relation, :target)) ->
        :shared_interface

      true ->
        :physical
    end
  end

  # Degree is computed across the complete immutable world by the native
  # metadata index. A page-local duplicate check cannot prove exclusivity.
  defp endpoint_pair(%{source_interface_degree: 1} = relation, :source),
    do: pair(relation.source_id, relation.source_if_index)

  defp endpoint_pair(%{target_interface_degree: 1} = relation, :target),
    do: pair(relation.target_id, relation.target_if_index)

  defp endpoint_pair(_relation, _endpoint), do: nil

  defp pair(id, index) when is_binary(id) and byte_size(id) > 0 and is_integer(index) and index > 0, do: {id, index}

  defp pair(_id, _index), do: nil
end
