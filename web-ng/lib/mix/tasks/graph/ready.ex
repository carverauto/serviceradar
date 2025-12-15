defmodule Mix.Tasks.Graph.Ready do
  @moduledoc """
  Verifies CNPG connectivity and Apache AGE graph readiness.

  Run with: `mix graph.ready`
  """

  use Mix.Task

  alias ServiceRadarWebNG.Graph

  @shortdoc "Verifies AGE graph readiness"

  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("Checking Apache AGE graph readiness...")

    case Graph.query("RETURN 1 as ok") do
      {:ok, _} ->
        Mix.shell().info("✓ AGE is reachable and the `serviceradar` graph is queryable")

      {:error, error} ->
        Mix.shell().error("✗ Graph query failed: #{inspect(error)}")

        Mix.shell().error(
          "Check CNPG_* env vars and that AGE is installed/enabled on the target database"
        )

        exit({:shutdown, 1})
    end
  end
end
