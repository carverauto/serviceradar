defmodule Mix.Tasks.Graph.Ready do
  @shortdoc "Verifies the Dgraph topology graph is reachable"

  @moduledoc """
  Verifies that the Dgraph topology graph is configured and answers a
  read-only query.

  Run with: `mix graph.ready`
  """

  use Boundary,
    top_level?: true,
    check: [in: false, out: false]

  use Mix.Task

  @dialyzer {:nowarn_function, run: 1}

  @probe "{ probe(func: has(device.id), first: 1) { uid } }"

  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("Checking Dgraph topology graph readiness...")

    case ServiceRadar.Dgraph.query(@probe) do
      {:ok, _} ->
        Mix.shell().info("Dgraph is reachable and the topology graph is queryable")

      {:error, error} ->
        Mix.shell().error("Topology graph query failed: #{inspect(error)}")
        Mix.shell().error("Check DGRAPH_URL, or DGRAPH_HOST with DGRAPH_PORT and DGRAPH_TLS_MODE")
        exit({:shutdown, 1})
    end
  end
end
