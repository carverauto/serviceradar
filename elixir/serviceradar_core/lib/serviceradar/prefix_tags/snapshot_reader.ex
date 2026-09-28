defmodule ServiceRadar.PrefixTags.SnapshotReader do
  @moduledoc "Bounded CNPG reads for building a complete prefix snapshot."

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  @batch_size 2_048

  def transaction(fun) do
    Repo.transaction(
      fn ->
        %{rows: [[isolation]]} = SQL.query!(Repo, "SHOW transaction_isolation", [])

        if isolation not in ["repeatable read", "serializable"] do
          SQL.query!(Repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
        end

        fun.()
      end,
      timeout: :infinity
    )
  end

  def stream(sql, params \\ []) do
    SQL.stream(Repo, sql, params, max_rows: @batch_size, timeout: :infinity)
  end
end
