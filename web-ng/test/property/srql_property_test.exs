defmodule ServiceRadarWebNG.SRQLPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ServiceRadarWebNG.Generators.SRQLGenerators
  alias ServiceRadarWebNG.TestSupport.PropertyOpts

  property "SRQL.query/1 never crashes for printable strings" do
    check all(
            query <- SRQLGenerators.printable_query_string(),
            max_runs: PropertyOpts.max_runs()
          ) do
      result = ServiceRadarWebNG.SRQL.query(query)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "SRQL.query_request/1 never crashes for JSON-like maps" do
    check all(
            payload <- SRQLGenerators.json_map(),
            max_runs: PropertyOpts.max_runs()
          ) do
      result = ServiceRadarWebNG.SRQL.query_request(payload)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
