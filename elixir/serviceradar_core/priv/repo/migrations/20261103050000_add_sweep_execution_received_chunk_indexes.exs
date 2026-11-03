defmodule ServiceRadar.Repo.Migrations.AddSweepExecutionReceivedChunkIndexes do
  @moduledoc """
  Core decides when an unleased sweep execution is complete, independent of
  the order its records arrive in. The close state lives in dedicated columns
  on the execution row, not in the user-visible scanner_metrics:

    * `received_chunk_indexes` - distinct data-chunk indexes ingested so far.
    * `expected_chunk_count` - chunk count carried on the results, once known.
    * `expected_chunk_indexes` - the exact data-chunk indexes the agent
      durably appended, set from a cancel marker; when NULL the expected set
      is 0..expected_chunk_count-1.
    * `close_cancelled` - latched when any record of the execution is
      cancelled; decides cancelled vs completed, never when to close.
    * `close_terminal_seen` - latched when the final data chunk or the cancel
      marker has been ingested.
  """

  use Ecto.Migration

  def up do
    alter table(:sweep_group_executions, prefix: prefix() || "platform") do
      add :received_chunk_indexes, {:array, :integer}, null: false, default: []
      add :expected_chunk_count, :integer
      add :expected_chunk_indexes, {:array, :integer}
      add :close_cancelled, :boolean, null: false, default: false
      add :close_terminal_seen, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:sweep_group_executions, prefix: prefix() || "platform") do
      remove :close_terminal_seen
      remove :close_cancelled
      remove :expected_chunk_indexes
      remove :expected_chunk_count
      remove :received_chunk_indexes
    end
  end
end
