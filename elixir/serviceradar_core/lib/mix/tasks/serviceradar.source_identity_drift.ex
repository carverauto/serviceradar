defmodule Mix.Tasks.Serviceradar.SourceIdentityDrift do
  @shortdoc "Audit and repair source-authoritative identity drift"

  @moduledoc """
  Audits and repairs source-authoritative identity drift.

  Dry-run is the default. `--apply` repairs only high-confidence metadata drift
  where one active device has one typed Armis identifier and no split/shared
  Armis mapping.

  ## Usage

      mix serviceradar.source_identity_drift --source armis
      mix serviceradar.source_identity_drift --source armis --json
      mix serviceradar.source_identity_drift --source armis --apply

  ## Options

    * `--source armis` - source type to audit; currently only `armis`
    * `--source-id <uuid>` - restrict reporting to one integration source
    * `--apply` - apply high-confidence repairs
    * `--json` - print the full JSON report
    * `--limit <n>` - maximum safe repairs to include/apply
    * `--no-record-conflicts` - do not upsert `source_identity_conflicts`
  """

  use Mix.Task

  alias ServiceRadar.Inventory.SourceIdentityDrift

  @switches [
    source: :string,
    source_id: :string,
    apply: :boolean,
    json: :boolean,
    limit: :integer,
    record_conflicts: :boolean
  ]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise(
        "Invalid arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}. " <>
          "See `mix help serviceradar.source_identity_drift`."
      )
    end

    Mix.Task.run("app.start")

    case String.downcase(opts[:source] || "armis") do
      "armis" ->
        report = SourceIdentityDrift.repair_armis(engine_opts(opts))
        print_report(report, Keyword.get(opts, :json, false))

      other ->
        Mix.raise("Unsupported --source #{inspect(other)}. Currently supported: armis")
    end
  end

  defp engine_opts(opts) do
    [
      apply: Keyword.get(opts, :apply, false),
      actor: "mix serviceradar.source_identity_drift",
      record_conflicts: Keyword.get(opts, :record_conflicts, true)
    ]
    |> put_if(:source_id, opts[:source_id])
    |> put_if(:limit, opts[:limit])
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_report(report, true) do
    Mix.shell().info(Jason.encode!(report, pretty: true))
  end

  defp print_report(report, false) do
    shell = Mix.shell()
    summary = report.summary
    categories = summary["categories"] || %{}

    shell.info("Source identity drift report")
    shell.info("mode: #{report.mode}")
    shell.info("source: #{report.source_type}")
    shell.info("source_id: #{report.source_id || "all"}")
    shell.info("conflicts: #{summary["total_count"] || 0}")
    shell.info("safe repairs: #{summary["safe_repair_count"] || 0}")
    shell.info("applied repairs: #{summary["applied_repair_count"] || 0}")

    if map_size(categories) > 0 do
      shell.info("")
      shell.info("Conflict categories:")

      categories
      |> Enum.sort_by(fn {category, _count} -> category end)
      |> Enum.each(fn {category, count} -> shell.info("  #{category}: #{count}") end)
    end

    print_examples(shell, report.repairs, "High-confidence repair candidates")
    print_examples(shell, report.conflicts, "Conflict examples")
  end

  defp print_examples(_shell, [], _heading), do: :ok

  defp print_examples(shell, rows, heading) do
    shell.info("")
    shell.info("#{heading}:")

    rows
    |> Enum.take(10)
    |> Enum.each(fn row ->
      shell.info(
        "  #{row.conflict_category} device=#{row.device_uid || "-"} ip=#{row.current_ip || "-"} " <>
          "mac=#{row.current_mac || "-"} source_id=#{row.source_id || "-"} " <>
          "source_identifier=#{row.source_identifier_type || "-"}:#{row.source_identifier_value || "-"} " <>
          "action=#{row.proposed_action || "-"} confidence=#{row.confidence || "-"}"
      )
    end)
  end
end
