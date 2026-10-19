defmodule Mix.Tasks.Serviceradar.Availability.Report do
  @shortdoc "Print the merged availability divergence report (read-only)"

  @moduledoc """
  Prints the stage-b divergence report of `add-merged-device-availability`: a short
  summary, then the full report as JSON. Read-only.

      mix serviceradar.availability.report
      mix serviceradar.availability.report --samples 5

  On a deployment, use the release instead:
  `bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.report()'`.
  """

  use Mix.Task

  alias ServiceRadar.Inventory.Availability.Operator

  @impl true
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [samples: :integer])

    Mix.Task.run("app.config")
    Operator.report(Keyword.take(opts, [:samples]))
    :ok
  end
end
