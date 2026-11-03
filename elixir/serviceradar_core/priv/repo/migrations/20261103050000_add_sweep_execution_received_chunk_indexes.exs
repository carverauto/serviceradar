defmodule ServiceRadar.Repo.Migrations.AddSweepExecutionReceivedChunkIndexes do
  @moduledoc """
  Core completes an unleased sweep execution when the number of distinct
  ingested chunk indexes reaches the chunk count carried on the results.
  The indexes live on the execution row so a chunk that arrives after the
  final record can still close it.
  """

  use Ecto.Migration

  def up do
    alter table(:sweep_group_executions, prefix: prefix() || "platform") do
      add :received_chunk_indexes, {:array, :integer}, null: false, default: []
    end
  end

  def down do
    alter table(:sweep_group_executions, prefix: prefix() || "platform") do
      remove :received_chunk_indexes
    end
  end
end
