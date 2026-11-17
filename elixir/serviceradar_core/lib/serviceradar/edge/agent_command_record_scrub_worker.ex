defmodule ServiceRadar.Edge.AgentCommandRecordScrubWorker do
  @moduledoc """
  One-time cleanup of `platform.agent_commands` rows written before
  `ServiceRadar.Edge.AgentCommandRecordPolicy` existed, enqueued once by
  migration `20261117015331_scrub_agent_command_records`.

  Every row is rewritten with `AgentCommandRecordPolicy.scrub_row/1`, the same
  Elixir rules the command bus and the result persister apply on each write, so
  the cleanup cannot drift from the runtime. Rows are read in primary-key order,
  `@batch_size` at a time, and each changed column of a row is updated by its
  own statement, guarded on that column still holding what was read: no
  statement holds more than one row lock, and a live writer's change to one
  column (the result persister rewrites `message`, `failure_reason`,
  `result_payload` and `progress_payload`) cannot stop the scrub of another.
  A column skipped that way is re-read by the next pass.

  A pass cannot see a row an old replica inserts behind its cursor during a
  rolling upgrade, so completion is decided from `pending/0` after each pass:
  the job completes once nothing is pending and otherwise snoozes for
  `@snooze_seconds` and runs another pass. When rows are still pending after
  pass `@max_passes`, it logs the remaining count and returns an error instead
  of completing.

  Once a pass finds nothing pending the job completes and is not enqueued
  again. During a rolling upgrade a Core pod still running the previous
  release can write an unredacted `camera.open_relay` row (its `source_url`
  and `lease_token`) after that point. Such rows are not cleaned by this job;
  they leave the table with the command table's normal 2-day retention
  (`AgentCommandCleanupWorker`).

  Re-running is safe: a clean row is not rewritten. `pending/0` counts the rows
  that still need it, writing nothing; it returns 0 once the cleanup is done.
  Check it once the rollout has finished and again after the retention period,
  from a running Core pod:

      /app/bin/serviceradar_core_elx rpc 'ServiceRadar.Edge.AgentCommandRecordScrubWorker.pending() |> IO.inspect()'

  To clean rows an old pod wrote without waiting for retention, run a pass by
  hand; it returns `{:ok, %{scanned: _, rewritten: _, skipped: _}}`:

      /app/bin/serviceradar_core_elx rpc 'ServiceRadar.Edge.AgentCommandRecordScrubWorker.run() |> IO.inspect()'

  The URLs in an `awx.launch_job` payload are not rewritten, by the policy's
  per-type rule: its args are bound to an authorized request body whose hash
  the credential broker checks. A launch row written before the policy keeps
  them, is not counted by `pending/0` for them, and leaves the table with the
  command table's normal 2-day retention (`AgentCommandCleanupWorker`).

  The worker can be deleted once every deployment has run it.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 20,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Edge.AgentCommandRecordPolicy
  alias ServiceRadar.Repo

  require Logger

  @batch_size 500
  @snooze_seconds 60
  @max_passes 60
  @scrubbed_columns [
    {"payload", "jsonb"},
    {"context", "jsonb"},
    {"message", "text"},
    {"failure_reason", "text"},
    {"result_payload", "jsonb"},
    {"progress_payload", "jsonb"}
  ]

  @type report :: %{
          scanned: non_neg_integer(),
          rewritten: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(%Oban.Job{meta: meta}), do: run_pass(Map.get(meta, "snoozed", 0) + 1)

  @doc """
  Runs scrub pass number `pass` and returns the job outcome: `:ok` when nothing
  is pending afterwards, `{:snooze, seconds}` while rows remain, and an error
  when rows remain after pass `#{@max_passes}`. Options: `:repo`, `:batch_size`.
  """
  @spec run_pass(pos_integer(), keyword()) ::
          :ok | {:snooze, pos_integer()} | {:error, String.t()}
  def run_pass(pass, opts \\ []) do
    {:ok, report} = run(opts)
    remaining = pending(opts)

    Logger.info(
      "Agent command record scrub pass #{pass}: scanned=#{report.scanned} " <>
        "rewritten=#{report.rewritten} skipped_concurrent=#{report.skipped} pending=#{remaining}"
    )

    cond do
      remaining == 0 ->
        :ok

      pass >= @max_passes ->
        Logger.error(
          "Agent command record scrub incomplete after #{pass} passes: " <>
            "#{remaining} rows still pending"
        )

        {:error, "#{remaining} agent command rows still pending after #{pass} passes"}

      true ->
        {:snooze, @snooze_seconds}
    end
  end

  @doc "Rewrites every row the policy changes. Options: `:repo`, `:batch_size`."
  @spec run(keyword()) :: {:ok, report()}
  def run(opts \\ []), do: process(true, opts)

  @doc "The number of rows the policy would still change, writing nothing."
  @spec pending(keyword()) :: non_neg_integer()
  def pending(opts \\ []) do
    {:ok, report} = process(false, opts)
    report.rewritten
  end

  defp process(apply?, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    scan(repo, batch_size, apply?, nil, %{scanned: 0, rewritten: 0, skipped: 0})
  end

  defp scan(repo, batch_size, apply?, after_id, report) do
    case fetch_batch(repo, batch_size, after_id) do
      [] ->
        {:ok, report}

      rows ->
        report =
          Enum.reduce(rows, %{report | scanned: report.scanned + length(rows)}, fn row, acc ->
            tally(acc, scrub(repo, apply?, row))
          end)

        scan(repo, batch_size, apply?, List.last(rows)["command_id"], report)
    end
  end

  defp tally(report, :clean), do: report
  defp tally(report, :rewritten), do: %{report | rewritten: report.rewritten + 1}
  defp tally(report, :skipped), do: %{report | skipped: report.skipped + 1}

  defp fetch_batch(repo, batch_size, after_id) do
    %{columns: columns, rows: rows} =
      repo.query!(
        """
        SELECT command_id::text AS command_id, command_type,
               payload, context, message, failure_reason, result_payload, progress_payload
        FROM platform.agent_commands
        WHERE $1::text IS NULL OR command_id > $1::text::uuid
        ORDER BY command_id
        LIMIT $2
        """,
        [after_id, batch_size]
      )

    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end

  defp scrub(repo, apply?, row) do
    scrubbed = AgentCommandRecordPolicy.scrub_row(row)

    cond do
      scrubbed == row -> :clean
      not apply? -> :rewritten
      true -> update(repo, row, scrubbed)
    end
  end

  defp update(repo, row, scrubbed) do
    results =
      for {column, type} <- @scrubbed_columns,
          Map.get(row, column) != Map.get(scrubbed, column) do
        update_column(
          repo,
          row["command_id"],
          column,
          type,
          Map.get(row, column),
          Map.get(scrubbed, column)
        )
      end

    if Enum.all?(results), do: :rewritten, else: :skipped
  end

  defp update_column(repo, command_id, column, type, old_value, new_value) do
    %{num_rows: num_rows} =
      repo.query!(
        """
        UPDATE platform.agent_commands
        SET #{column} = $2::#{type}
        WHERE command_id = $1::text::uuid
          AND #{column} IS NOT DISTINCT FROM $3::#{type}
        """,
        [command_id, new_value, old_value]
      )

    num_rows == 1
  end
end
