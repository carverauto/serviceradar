defmodule ServiceRadarWebNGWeb.SRQL.ScopeBuilderTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.ScopeBuilder

  defp filters(builder), do: Map.fetch!(builder, "filters")

  describe "parse_query_to_builder/1" do
    test "an empty scope is in sync with the default row" do
      assert {builder, true} = ScopeBuilder.parse_query_to_builder("")
      assert [%{"field" => _, "op" => "contains", "value" => ""}] = filters(builder)

      assert {_builder, true} = ScopeBuilder.parse_query_to_builder(nil)
    end

    test "parses equality filters" do
      assert {builder, true} = ScopeBuilder.parse_query_to_builder("source:armis tag:managed")

      assert filters(builder) == [
               %{"field" => "source", "op" => "equals", "value" => "armis"},
               %{"field" => "tag", "op" => "equals", "value" => "managed"}
             ]
    end

    test "parses negation and wildcards" do
      assert {builder, true} = ScopeBuilder.parse_query_to_builder("!source:armis hostname:%prod%")

      assert filters(builder) == [
               %{"field" => "source", "op" => "not_equals", "value" => "armis"},
               %{"field" => "hostname", "op" => "contains", "value" => "prod"}
             ]
    end

    test "ignores control tokens" do
      assert {builder, true} =
               ScopeBuilder.parse_query_to_builder("in:devices limit:10 sort:x:desc source:armis")

      assert [%{"field" => "source"}] = filters(builder)
    end

    test "an entity-only query is in sync with no filter rows" do
      # A scope of just `in:devices` has nothing to show as filter rows, which
      # the builder represents exactly. Treating it as unrepresentable would
      # warn on every new check's default scope.
      assert {builder, true} = ScopeBuilder.parse_query_to_builder("in:devices")
      assert [%{"value" => ""}] = filters(builder)

      assert {_builder, true} = ScopeBuilder.parse_query_to_builder("in:devices limit:10")
    end

    test "reports out of sync for a query it cannot represent" do
      # The flag is the contract: the caller must leave the raw string
      # authoritative rather than overwrite it with a lossy round-trip.
      assert {_builder, false} = ScopeBuilder.parse_query_to_builder("stats:count() as total")
    end
  end

  describe "build_query/1" do
    test "round-trips equality" do
      {builder, true} = ScopeBuilder.parse_query_to_builder("source:armis tag:managed")
      assert ScopeBuilder.build_query(builder) == "source:armis tag:managed"
    end

    test "round-trips negation and wildcards" do
      {builder, true} = ScopeBuilder.parse_query_to_builder("!source:armis hostname:%prod%")
      assert ScopeBuilder.build_query(builder) == "!source:armis hostname:%prod%"
    end

    test "round-trips list-valued fields" do
      {builder, true} = ScopeBuilder.parse_query_to_builder("discovery_sources:(sweep,armis)")
      assert ScopeBuilder.build_query(builder) == "discovery_sources:(sweep,armis)"
    end

    test "escapes spaces in values" do
      builder = %{"filters" => [%{"field" => "hostname", "op" => "equals", "value" => "a b"}]}
      assert ScopeBuilder.build_query(builder) == ~S(hostname:a\ b)
    end

    test "drops rows with no field or no value" do
      builder = %{
        "filters" => [
          %{"field" => "source", "op" => "equals", "value" => "armis"},
          %{"field" => "", "op" => "equals", "value" => "orphan"},
          %{"field" => "tag", "op" => "equals", "value" => ""}
        ]
      }

      assert ScopeBuilder.build_query(builder) == "source:armis"
    end
  end

  describe "update_builder/2" do
    test "accepts indexed params from a form" do
      builder =
        ScopeBuilder.update_builder(ScopeBuilder.default_builder_state(), %{
          "filters" => %{
            "0" => %{"field" => "source", "op" => "equals", "value" => "armis"},
            "1" => %{"field" => "tag", "op" => "equals", "value" => "managed"}
          }
        })

      assert ScopeBuilder.build_query(builder) == "source:armis tag:managed"
    end

    test "keeps indexed params in numeric, not lexical, order" do
      builder =
        ScopeBuilder.update_builder(ScopeBuilder.default_builder_state(), %{
          "filters" =>
            Map.new(0..10, fn i ->
              {to_string(i), %{"field" => "f#{i}", "op" => "equals", "value" => "v"}}
            end)
        })

      # Lexical ordering would put "10" between "1" and "2".
      assert ScopeBuilder.build_query(builder) ==
               Enum.map_join(0..10, " ", &"f#{&1}:v")
    end
  end
end
