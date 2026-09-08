defmodule Mix.Tasks.Serviceradar.SourceFacts.Backfill do
  @shortdoc "Promote existing Armis attachment metadata into canonical device facts"

  @moduledoc """
  Reads `metadata.armis_access_switch` / `metadata.armis_vlans` and writes
  per-source facts plus canonical `switch_port_attachment` / `vlan_uid`.

  Source-prefixed metadata is not removed. Raises if scanned Armis attachment
  rows produce zero canonical promotions.

      mix serviceradar.source_facts.backfill
      mix serviceradar.source_facts.backfill --limit 1000
  """

  use Mix.Task

  alias ServiceRadar.Inventory.SourceFacts.Reconciler

  @switches [limit: :integer]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)
    result = Reconciler.backfill(opts)
    Mix.shell().info("source-fact backfill scanned=#{result.scanned} promoted=#{result.promoted}")
  end
end
