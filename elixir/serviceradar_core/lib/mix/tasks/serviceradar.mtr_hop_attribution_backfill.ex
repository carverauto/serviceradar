defmodule Mix.Tasks.Serviceradar.MtrHopAttributionBackfill do
  @shortdoc "Backfill target_ip / device_id onto existing MTR hop rows"

  @moduledoc """
  Populates `target_ip` and `device_id` on `platform.mtr_hops` rows written before
  those columns existed, reading each hop's attribution from its trace.

  Dry run is the default: it reports how many rows are pending per chunk without
  writing. Review that before repeating with `--execute`.

      mix serviceradar.mtr_hop_attribution_backfill
      mix serviceradar.mtr_hop_attribution_backfill --execute
      mix serviceradar.mtr_hop_attribution_backfill --execute --max-chunks 5

  Safe to re-run and safe to interrupt. A NULL `target_ip` is the work marker, so
  a finished chunk is skipped on the next pass. Work is bounded chunk by chunk and
  again by `--batch-size` within a chunk, because one statement across every chunk
  of a hypertable is what OOM-kills a node.

  `rows_unrecoverable` counts hops whose trace has already aged out. Those can
  never be attributed and are reported separately rather than counted as remaining
  work, so a re-run does not look stuck on rows it cannot fix.

  Options:

    * `--execute` - write; otherwise report only
    * `--batch-size` - rows per statement, 1..200000 (default 10000)
    * `--max-chunks` - stop after this many chunks that had work
  """

  use Mix.Task

  alias ServiceRadar.Observability.MtrHopAttributionBackfill

  @switches [execute: :boolean, batch_size: :integer, max_chunks: :integer]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("Invalid arguments. See `mix help serviceradar.mtr_hop_attribution_backfill`.")
    end

    Mix.Task.run("app.start")

    run_opts =
      [mode: if(opts[:execute], do: :execute, else: :dry_run)]
      |> maybe_put(:batch_size, opts[:batch_size])
      |> maybe_put(:max_chunks, opts[:max_chunks])

    case MtrHopAttributionBackfill.run(run_opts) do
      {:ok, report} ->
        print_report(report)

      {:error, {:timescale_too_old, message}} ->
        Mix.raise(message)

      {:error, reason} ->
        Mix.raise("MTR hop attribution backfill failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_report(report) do
    Mix.shell().info("""
    MTR hop attribution backfill (#{report.mode})
      TimescaleDB:          #{report.timescale_version}
      chunks examined:      #{report.chunks_examined}
      chunks with work:     #{report.chunks_with_work}
      rows updated:         #{report.rows_updated}
      rows still pending:   #{report.rows_remaining}
      rows unrecoverable:   #{report.rows_unrecoverable} (trace already aged out)
    """)

    if report.mode == :dry_run and report.rows_remaining > 0 do
      Mix.shell().info("Re-run with --execute to apply.")
    end
  end
end
