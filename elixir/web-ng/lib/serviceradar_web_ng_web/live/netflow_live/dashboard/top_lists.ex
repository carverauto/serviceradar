defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.TopLists do
  @moduledoc false

  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers

  @top_n 10
  @conversation_merge_window @top_n * 5

  def load_top_n(srql_mod, scope, base, group_field, sort_field) do
    query =
      "#{base} stats:sum(bytes_total) as bytes_total stats:sum(packets_total) as packets_total by #{group_field} sort:#{sort_field}:desc limit:#{@top_n}"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)
      name = get_field(p, group_field)

      %{
        ip: name,
        app: name,
        protocol: name,
        port: name,
        bytes: to_number(get_field(p, "bytes_total")),
        packets: to_number(get_field(p, "packets_total"))
      }
    end)
  end

  def load_top_conversations(srql_mod, scope, base, sort_field) do
    # §37.3: fetch a wider directional window (A->B and B->A come back as
    # separate rows), then canonical_conversation_merge/1 folds the two
    # directions of each pair so a conversation isn't double-counted as two
    # rows. The merge window is @conversation_merge_window; the final list is
    # trimmed to @top_n after merging.
    query =
      "#{base} stats:sum(bytes_total) as bytes_total stats:sum(packets_total) as packets_total by src_endpoint_ip,dst_endpoint_ip sort:#{sort_field}:desc limit:#{@conversation_merge_window}"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)

      %{
        src_ip: get_field(p, "src_endpoint_ip"),
        dst_ip: get_field(p, "dst_endpoint_ip"),
        bytes: to_number(get_field(p, "bytes_total")),
        packets: to_number(get_field(p, "packets_total"))
      }
    end)
    |> canonical_conversation_merge()
  end

  # §37.3: fold the two directions of each A<->B conversation into one row.
  # Groups by the canonical (unordered) IP pair, sums bytes+packets, orients
  # the display (src_ip, dst_ip) to the direction with larger bytes so a human
  # reads the dominant direction first, then sorts by total bytes desc and
  # trims to @top_n.
  defp canonical_conversation_merge(rows) do
    rows
    |> Enum.reject(fn r -> is_nil(r.src_ip) or is_nil(r.dst_ip) end)
    |> Enum.group_by(fn r -> Enum.sort([r.src_ip, r.dst_ip]) end)
    |> Enum.map(fn {_pair, group} ->
      {src_ip, dst_ip, bytes, packets} = fold_conversation_directions(group)
      %{src_ip: src_ip, dst_ip: dst_ip, bytes: bytes, packets: packets}
    end)
    |> Enum.sort_by(& &1.bytes, :desc)
    |> Enum.take(@top_n)
  end

  # Sums bytes/packets across both directions of a conversation and orients the
  # display pair to the direction with the larger byte total.
  defp fold_conversation_directions(group) do
    {total_bytes, total_packets, dominant} =
      Enum.reduce(group, {0, 0, nil}, fn r, {b, p, dom} ->
        new_b = b + r.bytes
        new_dom = if is_nil(dom) or r.bytes > dom.bytes, do: r, else: dom
        {new_b, p + r.packets, new_dom}
      end)

    {dominant.src_ip, dominant.dst_ip, total_bytes, total_packets}
  end
end
