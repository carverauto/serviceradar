defmodule ServiceRadar.Inventory.Availability.Operator do
  @moduledoc """
  Operator entry points for the merged availability rollout, usable from a running
  release, a release `eval`, or the `mix serviceradar.availability.*` tasks. Each starts
  the repo when nothing has (`eval`) and reuses it when the application runs (`rpc`).

      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.report()'
      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.switch("shadow")'
      bin/serviceradar_core eval 'ServiceRadar.Inventory.Availability.Operator.report()'

  `report/1` prints the human summary, then the JSON report, and changes nothing.
  `switch/1` is the mode switch (`Mode.enter_shadow/0` or `Mode.enter_legacy/0`).
  """

  alias ServiceRadar.Inventory.Availability.DivergenceReport
  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Repo

  @doc "Prints the divergence report (summary, then JSON) and returns it."
  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    with_repo(fn ->
      report = DivergenceReport.build(opts)
      IO.puts(DivergenceReport.summary_text(report))
      IO.puts(Jason.encode!(report, pretty: true))
      report
    end)
  end

  @doc ~s(Switches the availability mode to `"shadow"` or `"legacy"` and prints the outcome.)
  @spec switch(String.t()) :: {:ok, map()} | {:error, term()}
  def switch(mode) do
    with_repo(fn ->
      result =
        case mode do
          "shadow" -> Mode.enter_shadow()
          "legacy" -> Mode.enter_legacy()
          other -> {:error, {:unsupported_mode, other}}
        end

      IO.puts("availability mode switch: #{inspect(result)}")
      result
    end)
  end

  defp with_repo(fun) do
    {:ok, result, _started} = Ecto.Migrator.with_repo(Repo, fn _repo -> fun.() end)
    result
  end
end
