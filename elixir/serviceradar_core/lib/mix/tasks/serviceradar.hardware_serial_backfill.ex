defmodule Mix.Tasks.Serviceradar.HardwareSerialBackfill do
  @shortdoc "Backfill manufacturer-scoped hardware serial identifiers"

  @moduledoc """
  Plans or executes a bounded hardware serial identifier backfill.

  Dry-run is the default. Review its plan hash and conflict counts before
  repeating the same bounded page with `--execute`.

      mix serviceradar.hardware_serial_backfill --limit 5000
      mix serviceradar.hardware_serial_backfill --limit 5000 --execute
      mix serviceradar.hardware_serial_backfill --after-uid sr:last-seen

  Options:

    * `--execute` - register unambiguous identifiers
    * `--limit` - devices scanned, 1..50000 (default 5000)
    * `--after-uid` - continue after this canonical UID
    * `--sample-limit` - report entries printed, 0..1000 (default 100)
  """

  use Mix.Task

  alias ServiceRadar.Inventory.Identity.HardwareSerialBackfill

  @switches [execute: :boolean, limit: :integer, after_uid: :string, sample_limit: :integer]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("Invalid arguments. See `mix help serviceradar.hardware_serial_backfill`.")
    end

    Mix.Task.run("app.start")

    run_opts = [
      mode: if(opts[:execute], do: :execute, else: :dry_run),
      limit: validate_range(opts[:limit] || 5_000, "--limit", 1, 50_000),
      after_uid: opts[:after_uid]
    ]

    sample_limit = validate_range(opts[:sample_limit] || 100, "--sample-limit", 0, 1_000)

    case HardwareSerialBackfill.run(run_opts) do
      {:ok, report} ->
        entries = Map.get(report, :entries, [])

        printable =
          report
          |> Map.put(:entries, Enum.take(entries, sample_limit))
          |> Map.put(:entries_truncated, length(entries) > sample_limit)

        Mix.shell().info(Jason.encode!(printable, pretty: true))

      {:error, reason} ->
        Mix.raise("Hardware serial backfill failed: #{inspect(reason)}")
    end
  end

  defp validate_range(value, _flag, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: value

  defp validate_range(value, flag, minimum, maximum) do
    Mix.raise("#{flag} must be between #{minimum} and #{maximum}, got: #{inspect(value)}")
  end
end
