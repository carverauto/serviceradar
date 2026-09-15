defmodule ServiceRadar.AnalyticsStore.TimescaleDriver do
  @moduledoc """
  Analytics-store driver that writes and reads CNPG hypertables.

  Byte-identical to the pre-store EventWriter path: `BulkInsert.insert_all/4`
  with the caller's `on_conflict` / `returning` options.
  """

  @behaviour ServiceRadar.AnalyticsStore.Driver

  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.Repo

  @impl true
  def write(_table, [], _opts), do: {:ok, 0}

  def write(table, rows, opts) when is_list(rows) do
    repo = Keyword.get(opts, :repo, Repo)
    insert_opts = Keyword.take(opts, [:on_conflict, :returning, :placeholders])

    {count, _} = BulkInsert.insert_all(repo, table, rows, insert_opts)
    {:ok, count}
  rescue
    exception -> {:error, exception}
  end

  @impl true
  def query(sql, params, opts) when is_binary(sql) and is_list(params) do
    repo = Keyword.get(opts, :repo, Repo)
    timeout = Keyword.get(opts, :timeout, 15_000)
    repo.query(sql, params, timeout: timeout)
  end

  @impl true
  def dialect, do: :postgres
end
