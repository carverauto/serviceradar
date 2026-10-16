defmodule ServiceRadarWebNG.Topology.BitmapQueryControlTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.BitmapAddress
  alias ServiceRadarWebNG.Topology.BitmapCursor
  alias ServiceRadarWebNG.Topology.BitmapExpression
  alias ServiceRadarWebNG.Topology.Native

  @moduletag :db_free

  @facets ["vendor", "region", "availability"]
  @dictionary <<17::128>>
  @epoch <<18::128>>
  @authority <<19::256>>

  test "normalized browser expressions preserve nested exclusions and exact same-facet counts in native queries" do
    expression = %{
      "all" => [
        %{"any" => [predicate("vendor", "example-a"), predicate("region", "example-west")]},
        %{"except" => predicate("availability", "unavailable")}
      ]
    }

    {:ok, parsed} = BitmapExpression.parse(%{"expression" => expression}, @facets)
    reversed = put_in(expression["all"], Enum.reverse(expression["all"]))
    {:ok, equivalent} = BitmapExpression.parse(%{"expression" => reversed}, @facets)
    assert parsed.digest == equivalent.digest

    index =
      index([
        {3, true, [{"vendor", "example-a"}, {"region", "example-east"}, {"availability", "healthy"}]},
        {7, true, [{"vendor", "example-b"}, {"region", "example-west"}, {"availability", "healthy"}]},
        {11, true, [{"vendor", "example-a"}, {"availability", "unavailable"}]},
        {13, false, [{"vendor", "example-a"}]},
        {4_294_967_295, true, [{"vendor", "example-a"}]}
      ])

    assert {:ok, {query, 1, "initial", 3}} = query(index, parsed)
    assert {:ok, [3, 7, 4_294_967_295]} = Native.bitmap_query_page(query, @authority, 0, 128, 1000)

    assert {:ok, [2, 1, 0]} =
             Native.bitmap_query_facets(
               query,
               @authority,
               [
                 {"vendor", "example-a"},
                 {"vendor", "example-b"},
                 {"availability", "unavailable"}
               ],
               1000
             )

    Native.bitmap_query_close(query)
  end

  test "a cursor resumes current membership after a revision change and rejects query or authority substitution" do
    {:ok, parsed} = BitmapExpression.parse(%{"expression" => predicate("vendor", "example-a")}, @facets)
    context = %{dictionary_epoch: @dictionary, query_digest: parsed.digest, authority: @authority}
    index = index([{3, true, [{"vendor", "example-a"}]}, {7, true, [{"vendor", "example-a"}]}])

    assert {:ok, {first, 1, "initial", 2}} = query(index, parsed)
    assert {:ok, [3]} = Native.bitmap_query_page(first, @authority, 0, 1, 1000)
    cursor = BitmapCursor.sign(context, 3)
    Native.bitmap_query_close(first)

    assert {:ok, %{revision: 2}} =
             Native.bitmap_index_publish(
               index,
               1,
               "updated",
               [
                 {7, false, []},
                 {11, true, [{"vendor", "example-a"}]}
               ],
               true
             )

    assert {:ok, position} = BitmapCursor.after_ordinal(cursor, context)
    assert {:ok, {second, 2, "updated", 2}} = query(index, parsed)
    assert {:ok, [11]} = Native.bitmap_query_page(second, @authority, position, 128, 1000)
    Native.bitmap_query_close(second)

    for changed <- [
          %{context | authority: <<20::256>>},
          %{context | dictionary_epoch: <<21::128>>},
          %{context | query_digest: <<22::256>>}
        ] do
      assert {:error, :invalid_cursor} = BitmapCursor.after_ordinal(cursor, changed)
    end

    assert {:error, :invalid_cursor} = BitmapCursor.after_ordinal(cursor <> "tampered", context)
  end

  test "source hosts and canonical query networks share typed address identity without DNS" do
    assert {:ok, <<192, 0, 2, 7>>} = BitmapAddress.source("192.0.2.7/24")
    assert {:ok, <<192, 0, 2, 7>>} = BitmapAddress.source("::ffff:192.0.2.7")
    assert {:ok, <<0xFE80::16, 0::96, 7::16>>} = BitmapAddress.source("fe80::7%example0/64")
    assert {:ok, <<192, 0, 2, 0>>, 24} = BitmapAddress.cidr("192.0.2.7/24")
    assert {:ok, <<192, 0, 2, 0>>, 24} = BitmapAddress.cidr("::ffff:192.0.2.7/120")
    assert {:ok, <<0::128>>, 0} = BitmapAddress.cidr("2001:db8::7/0")

    assert {:ok, first} = BitmapExpression.parse(%{"expression" => %{"ip_cidr" => "192.0.2.7/24"}}, @facets)
    assert {:ok, mapped} = BitmapExpression.parse(%{"expression" => %{"ip_cidr" => "::ffff:192.0.2.9/120"}}, @facets)
    assert first.digest == mapped.digest

    for value <- [
          "router.example.com",
          "127.1",
          "192.0.2.7/",
          "192.0.2.7/33",
          "fe80::7%example0/64",
          "::ffff:192.0.2.7/95"
        ] do
      assert {:error, :invalid_cidr} = BitmapExpression.parse(%{"expression" => %{"ip_cidr" => value}}, @facets)
    end

    assert {:error, :invalid_address} = BitmapAddress.source("router.example.com")
  end

  test "prefix controls canonicalize literal whitespace while retaining same-key pairs and source identity" do
    expression = %{"tag_key_prefix" => " role", "prefix" => " edge "}
    canonical = %{"tag_key_prefix" => "role", "prefix" => "edge"}
    assert {:ok, parsed} = BitmapExpression.parse(%{"expression" => expression}, @facets)
    assert {:ok, normalized} = BitmapExpression.parse(%{"expression" => canonical}, @facets)
    assert parsed.digest == normalized.digest

    assert {:ok, exact} =
             BitmapExpression.parse(%{"expression" => %{"tag_key_prefix" => "role", "value" => "edge"}}, @facets)

    refute exact.digest == parsed.digest

    for expression <- [
          %{"facet" => "vendor", "prefix" => " "},
          %{"tag_key_prefix" => ""},
          %{"tag_key_prefix" => "role", "prefix" => "edge", "value" => "edge"},
          %{"prefix_tag" => %{"source" => "manual", "label" => "example", "extra" => true}}
        ] do
      assert {:error, :invalid_predicate} = BitmapExpression.parse(%{"expression" => expression}, @facets)
    end

    assert {:ok, label} =
             BitmapExpression.parse(
               %{"expression" => %{"prefix_tag" => %{"source" => "manual", "label" => "example"}}},
               @facets
             )

    assert {:ok, other} =
             BitmapExpression.parse(
               %{"expression" => %{"prefix_tag" => %{"source" => "example-import", "label" => "example"}}},
               @facets
             )

    refute label.digest == other.digest

    assert {:error, :invalid_predicate} =
             BitmapExpression.parse(%{"facets" => [%{"facet" => "vendor", "prefix" => "ex"}]}, @facets)
  end

  test "untrusted control cannot select undeclared fields or bypass expression and request bounds" do
    assert {:error, :invalid_query} = BitmapExpression.parse(%{"metadata.secret" => "x"}, @facets)
    assert {:error, :unsupported_entity} = BitmapExpression.parse(%{"kind" => "interface"}, @facets)

    assert {:error, :unsupported_facet} =
             BitmapExpression.parse(%{"expression" => predicate("metadata.secret", "x")}, @facets)

    assert {:error, :invalid_predicate} =
             BitmapExpression.parse(%{"expression" => %{"facet" => "vendor", "value" => "x", "extra" => true}}, @facets)

    assert {:error, :expression_budget} =
             BitmapExpression.parse(
               %{
                 "expression" => %{
                   "all" => [
                     %{"all" => List.duplicate(predicate("vendor", "example-a"), 32)},
                     predicate("region", "example-west")
                   ]
                 }
               },
               @facets
             )

    deep = Enum.reduce(1..9, predicate("vendor", "example-a"), fn _, child -> %{"except" => child} end)
    assert {:error, :expression_budget} = BitmapExpression.parse(%{"expression" => deep}, @facets)

    assert {:error, :query_budget} =
             BitmapExpression.parse(%{"expression" => predicate("vendor", String.duplicate("x", 16_384))}, @facets)

    assert {:error, :invalid_page_limit} = BitmapExpression.parse(%{"limit" => 129}, @facets)
  end

  defp index(rows) do
    {:ok, index} = Native.bitmap_index_new(@dictionary, @epoch, :device, @facets)
    on_exit(fn -> Native.bitmap_index_close(index) end)
    {:ok, %{revision: 1}} = Native.bitmap_index_publish(index, 0, "initial", rows, true)
    index
  end

  defp query(index, parsed),
    do: Native.bitmap_index_query(index, @dictionary, @epoch, :device, @authority, parsed.program, 1000)

  defp predicate(facet, value), do: %{"facet" => facet, "value" => value}
end
