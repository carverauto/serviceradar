defmodule ServiceRadar.DgraphDownstreamTest do
  use ExUnit.Case, async: true

  test "downstream_of never returns postpone or sequence" do
    Code.ensure_loaded(ServiceRadar.Dgraph)
    {:module, _} = Code.ensure_compiled(ServiceRadar.Dgraph)
    refute function_exported?(ServiceRadar.Dgraph, :postpone, 2)
    refute function_exported?(ServiceRadar.Dgraph, :sequence, 2)
    assert function_exported?(ServiceRadar.Dgraph, :downstream_of, 2)
  end
end
